import Foundation
import RestoreyCore
import Synchronization

/// The testable heart of the agent: it owns `config.json`, `state.json` and the plans' keychain
/// secrets (the agent is their only writer), tracks in-flight runs, and builds `AgentStatus`.
///
/// If either file cannot be read when the agent starts (newer schema, corrupt, no migration), the agent
/// enters a config-error state: it reports the problem in `status`, refuses every mutating call and
/// never writes either file, so the user's plans survive (Review Focus 2). When only `state.json` is
/// unreadable the plans are still listed, each stopped with the reason.
///
/// Calls that write are serialised through a FIFO write gate, so two requests arriving together over
/// XPC can never interleave across the stores' `await`s and lose an update.
///
/// While draining (`prepareForRestart`), every mutating call except `pause` is refused. Pause stays
/// allowed so the user can still stop a long first backup; the next agent honours `pausedUntil`.
public actor AgentState {
    public static let pauseDuration: TimeInterval = 3600
    /// Progress pushes are at most this often; phase changes are always pushed.
    public static let progressPushInterval: TimeInterval = 0.5
    static let stateSchemaVersion = 1

    private struct RunProgress {
        var progress: BackupStatus?
        var retrying: String?
    }

    private let configStore: any PayloadStore<ConfigFile>
    private let stateStore: any PayloadStore<RunState>
    private let secrets: any SecretStore
    private let credentialsDirectory: URL
    let now: @Sendable () -> Date

    private(set) var config: ConfigFile
    private(set) var runState: RunState
    let loadError: String?
    /// `config.json` loaded but `state.json` did not: the plans are listed as stopped.
    private let onlyStateUnreadable: Bool

    public private(set) var isDraining = false
    /// Why the agent is draining, once it is. A restart drain wins over a re-registration one.
    public private(set) var drainPurpose: DrainPurpose?
    private var running: [UUID: RunProgress] = [:]
    /// Plans `deletePlan` has started removing. No run may begin on them.
    private var deleting: Set<UUID> = []
    /// `prepareForRestart` callers, woken whenever the agent may have become idle.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Per plan, why the last helper request failed to read the keychain (the runner reports it).
    private var helperFailures: [UUID: String] = [:]

    /// Runs backups, creates and adopts repositories (`attach(runner:)`). Weak: the runner holds this state.
    weak var runner: PlanRunner?
    /// The latest Full Disk Access probe, as the runner last saw it; nil until it has run.
    var fdaMissing: Bool?

    /// Posts the alerts (`attach(notifier:log:)`); without one, no alert is delivered.
    var notifier: (any AlertNotifying)?
    var alertLog: @Sendable (String) -> Void = { _ in }
    /// The alert delivery in progress (AgentState+Alerts.swift), and whether another was asked for meanwhile.
    var alertDelivery: Task<Void, Never>?
    var alertDeliveryAgain = false
    /// How long each notifier call may take before it counts as failed.
    var alertCallTimeout: Duration = .seconds(10)
    /// The agent-wide load-error alert. In memory only: `state.json` can't be trusted in that state.
    var loadErrorAlert: AlertNotificationState?
    /// The status that raised each plan's `checkInRejected`, for the notification's text.
    var checkInRejectedStatus: [UUID: Int] = [:]
    /// Notifier calls still suspended, by key (`authorisation`, or `post.<identifier>`), even past their
    /// timeout, with the call's token and when it started. No second call with the same key is made
    /// until the first returns, or until it has been held for `notifierCallAbandonment`.
    var outstandingNotifierCalls: [String: (token: UUID, since: Date)] = [:]
    /// The notifier's last answer about authorisation; `.none` until it has answered once.
    var lastAuthorisation: Bool?? = .none
    /// An authorisation call was abandoned and no answer has come since: notifications aren't working.
    var authorisationAbandoned = false

    private var observer: (@Sendable (AgentStatus) -> Void)?
    private var lastProgressPush: Date?
    /// What each plan looked like in the last push, for `pushStatusIfChanged`.
    private var lastPushed: [UUID: PushedPlan] = [:]

    /// The parts of a plan's status that can change with time alone.
    private struct PushedPlan: Equatable {
        var phase: PlanPhase
        var alerts: [AlertCondition]
        var due: Bool

        init(_ status: PlanStatus, now: Date) {
            phase = status.phase
            alerts = status.alerts
            due = status.nextRunAt.map { $0 <= now } ?? false
        }
    }

    /// Loads both stores. A load failure is kept as the config error rather than thrown.
    /// - Parameters:
    ///   - credentialsDirectory: where `CredentialsFile` keeps the plans' `s3/<id>.ini` files.
    public init(
        configStore: any PayloadStore<ConfigFile>,
        stateStore: any PayloadStore<RunState>,
        secrets: any SecretStore,
        credentialsDirectory: URL,
        now: @escaping @Sendable () -> Date
    ) async {
        await self.init(
            configStore: configStore, stateStore: stateStore, secrets: secrets,
            credentialsDirectory: credentialsDirectory, now: now, startupError: nil)
    }

    /// The agent's layout: `config.json`, `state.json` and the credentials files all in `directory`
    /// (`Identity.applicationSupportDirectory()`), which is created with mode 0700.
    public init(directory: URL, secrets: any SecretStore, now: @escaping @Sendable () -> Date) async {
        var startupError: String?
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // createDirectory leaves the mode of an existing folder alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            startupError = "Restorey can't create its settings folder \(directory.path): \(error.localizedDescription)"
        }
        await self.init(
            configStore: Self.configStore(in: directory), stateStore: Self.stateStore(in: directory),
            secrets: secrets, credentialsDirectory: directory, now: now, startupError: startupError)
    }

    public static func configStore(in directory: URL) -> VersionedStore<ConfigFile> {
        VersionedStore(
            fileURL: directory.appendingPathComponent("config.json"),
            currentVersion: ConfigMigrations.currentVersion, migrations: ConfigMigrations.migrations)
    }

    public static func stateStore(in directory: URL) -> VersionedStore<RunState> {
        VersionedStore(
            fileURL: directory.appendingPathComponent("state.json"),
            currentVersion: stateSchemaVersion, migrations: [:])
    }

    private init(
        configStore: any PayloadStore<ConfigFile>,
        stateStore: any PayloadStore<RunState>,
        secrets: any SecretStore,
        credentialsDirectory: URL,
        now: @escaping @Sendable () -> Date,
        startupError: String?
    ) async {
        var loadError = startupError
        var config: ConfigFile?
        var runState: RunState?
        if loadError == nil {
            do {
                config = try await configStore.load() ?? ConfigFile()
            } catch {
                loadError = Self.describeLoadFailure(error, file: "config.json")
            }
        }
        if loadError == nil {
            do {
                runState = try await stateStore.load() ?? RunState()
            } catch {
                loadError = Self.describeLoadFailure(error, file: "state.json")
            }
        }
        self.configStore = configStore
        self.stateStore = stateStore
        self.secrets = secrets
        self.credentialsDirectory = credentialsDirectory
        self.now = now
        self.config = config ?? ConfigFile()
        self.runState = runState ?? RunState()
        self.loadError = loadError
        self.onlyStateUnreadable = config != nil && runState == nil
    }

    private static func describeLoadFailure(_ error: any Error, file: String) -> String {
        let leftAlone = "The file has been left as it is."
        switch error as? VersionedStoreError {
        case .newerSchema(let found, let supported)?:
            return "\(file) was written by a newer version of Restorey (schema \(found); this version reads up to \(supported)). Update Restorey. \(leftAlone)"
        case .corrupt(let underlying)?:
            return "\(file) can't be read: \(underlying). \(leftAlone)"
        case .missingMigration(let from)?:
            return "\(file) uses schema \(from), which this version of Restorey can't upgrade. \(leftAlone)"
        case nil:
            return "\(file) can't be read: \(error.localizedDescription). \(leftAlone)"
        }
    }

    // MARK: Status

    /// Called with the new status after every phase change, and for progress at most every
    /// `progressPushInterval`. The agent forwards it to connected apps.
    public func setStatusObserver(_ observer: (@Sendable (AgentStatus) -> Void)?) {
        self.observer = observer
    }

    public func status() -> AgentStatus {
        let now = now()
        if let loadError {
            // Without history nothing can be scheduled, but the user still sees their plans.
            let plans = onlyStateUnreadable
                ? config.plans.map {
                    PlanStatus(plan: $0, phase: .stopped(reason: loadError), lastRecord: nil, nextRunAt: nil,
                               alerts: [.configurationError])
                }
                : []
            return AgentStatus(plans: plans, configError: loadError, fdaMissing: nil, generatedAt: now)
        }
        return AgentStatus(
            plans: config.plans.map { planStatus($0, now: now) }, configError: nil, fdaMissing: fdaMissing,
            generatedAt: now)
    }

    private func planStatus(_ plan: Plan, now: Date) -> PlanStatus {
        let history = runState.plans[plan.id] ?? PlanRunHistory()
        let phase: PlanPhase
        if let run = running[plan.id] {
            phase = .running(run.progress, retrying: run.retrying)
        } else if let reason = history.stoppedReason {
            phase = .stopped(reason: reason)
        } else if let until = history.pausedUntil, until > now {
            phase = .paused(until: until)
        } else if case .skipped(let reason)? = history.recent.first?.outcome {
            phase = .skipped(reason)
        } else {
            phase = .idle
        }
        let next = nextRunDate(plan: plan, history: history, now: now)
        let alerts = activeConditions(history: history, plan: plan, now: now)
            .union(history.activeAlerts.keys)
            .sorted { $0.rawValue < $1.rawValue }
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: history.recent.first,
            nextRunAt: next == .distantFuture ? nil : next, alerts: alerts)
    }

    /// Pushes the status and, unless `deliveringAlerts` is false, has the alerts delivered for it: every
    /// status change can raise or clear one. Progress pushes and the delivery's own push pass false.
    @discardableResult
    func pushStatus(deliveringAlerts: Bool = true) -> AgentStatus {
        let status = status()
        lastPushed = Self.pushed(status)
        observer?(status)
        if deliveringAlerts { scheduleAlertDelivery() }
        return status
    }

    /// Pushes the status if a plan's phase, alerts or being due has changed since the last push with
    /// nothing having called for one: a pause running out, a plan falling due, an overdue alert. The
    /// scheduler calls this on every tick.
    public func pushStatusIfChanged() {
        guard Self.pushed(status()) != lastPushed else { return }
        pushStatus()
    }

    private static func pushed(_ status: AgentStatus) -> [UUID: PushedPlan] {
        Dictionary(status.plans.map { ($0.plan.id, PushedPlan($0, now: status.generatedAt)) }) { first, _ in first }
    }

    // MARK: Plans

    /// Validates, writes the secrets, then the config. If a secret write or the config write fails,
    /// every submitted secret is put back as it was (new keys deleted) and the config is unchanged.
    ///
    /// `recoveryKitConfirmedAt` is agent-owned. A new plan starts unconfirmed. An existing plan keeps its
    /// confirmation only if the repository is the same and every submitted secret equals the keychain's
    /// current value; otherwise the recovery details the user saved no longer match, so it is cleared.
    ///
    /// The same change also clears a stop (`stoppedReason`, e.g. after a wrong password) and refreshes the
    /// plan's alerts: the user has changed what restic opens the repository with, so the next run tries it
    /// (Ruling R34). An unchanged resave keeps the stop.
    ///
    /// A changed check-in URL, or none (`hasCheckInURL` false), clears `checkInRejected` (Ruling R48): that
    /// verdict was about the old URL, and with no URL it could never clear.
    ///
    /// `hasCheckInURL: false` deletes any stored check-in URL (and a check-in URL sent with it is refused).
    /// Clients must carry `hasCheckInURL` over from the stored plan like any other field, since they can't
    /// read the URL back: sending `false` for a plan that has one removes its dead-man's switch.
    public func savePlan(_ request: SavePlanRequest) async throws -> AgentStatus {
        try requireMutable()
        let errors = request.plan.validationErrors()
        guard errors.isEmpty else { throw AgentError.invalidPlan(errors) }
        guard request.secrets.allSatisfy({ $0.key.planID == request.plan.id }) else {
            throw AgentError.foreignSecret
        }
        let checkInKey = SecretKey.checkInURL(request.plan.id)
        if !request.plan.hasCheckInURL, request.secrets.contains(where: { $0.key == checkInKey }) {
            throw AgentError.invalidRequest("a check-in URL was sent for a plan saved without one")
        }
        return try await serialisedWrite {
            // A plan saved without a check-in URL loses any stored one, so it is never pinged.
            let planSecrets = try PlanSecrets(
                store: secrets, entries: request.secrets,
                deletions: request.plan.hasCheckInURL ? [] : [checkInKey])
            var plan = request.plan
            var updated = config
            var credentialsChanged = false
            let checkInChanged = !plan.hasCheckInURL || planSecrets.changesValue(of: .checkInURL(plan.id))
            if let index = updated.plans.firstIndex(where: { $0.id == plan.id }) {
                let stored = updated.plans[index]
                let unchanged = stored.repository == plan.repository && !planSecrets.changesAnyValue
                credentialsChanged = !unchanged
                plan.recoveryKitConfirmedAt = unchanged ? stored.recoveryKitConfirmedAt : nil
                updated.plans[index] = plan
            } else {
                plan.recoveryKitConfirmedAt = nil
                updated.plans.append(plan)
            }

            try planSecrets.write()
            do {
                try await saveConfig(updated)
            } catch {
                let message = (error as? AgentError)?.message ?? "\(error)"
                throw AgentError.storage(message + PlanSecrets.describe(planSecrets.restore()))
            }
            let clearStop = credentialsChanged && runState.plans[plan.id]?.stoppedReason != nil
            let clearCheckIn = checkInChanged && runState.plans[plan.id]?.activeAlerts[.checkInRejected] != nil
            if checkInChanged { checkInRejectedStatus[plan.id] = nil }
            if clearStop || clearCheckIn {
                var state = runState
                if clearStop {
                    state.plans[plan.id]?.stoppedReason = nil
                    PlanRunner.refreshAlerts(&state.plans[plan.id, default: PlanRunHistory()], plan: plan, now: now())
                }
                if clearCheckIn { state.plans[plan.id]?.activeAlerts[.checkInRejected] = nil }
                do {
                    try await saveState(state)
                } catch {
                    let detail = (error as? AgentError)?.message ?? "\(error)"
                    let what = clearStop ? "its stop" : "its check-in alert"
                    throw AgentError.storage("\(plan.name) was saved, but Restorey couldn't clear \(what): \(detail)")
                }
            }
            return pushStatus()
        }
    }

    /// Removes the plan from the config, then its secrets, credentials file and history. The
    /// repository is never touched. A running plan cannot be deleted, and from the moment this is called
    /// no run can begin on the plan.
    public func deletePlan(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        let plan = try requirePlan(id)
        guard !deleting.contains(id) else { throw AgentError.planDeleting(name: plan.name) }
        guard running[id] == nil else { throw AgentError.planRunning(name: plan.name) }
        // Marked before the first await, so beginRun can't slip in while this waits on the stores.
        deleting.insert(id)
        defer { deleting.remove(id) }

        return try await serialisedWrite {
            var updated = config
            updated.plans.removeAll { $0.id == id }
            try await saveConfig(updated)

            // The plan is gone from the config, so finish every clean-up step before reporting a failure.
            var failures: [String] = []
            do { try secrets.deleteAll(planID: id) } catch { failures.append("its Keychain items (\(error))") }
            do {
                try CredentialsFile.remove(planID: id, directory: credentialsDirectory)
            } catch {
                failures.append("its credentials file (\(error))")
            }
            if runState.plans[id] != nil {
                var state = runState
                state.plans[id] = nil
                do { try await saveState(state) } catch { failures.append("its history (\(error))") }
            }
            let status = pushStatus()
            if !failures.isEmpty {
                throw AgentError.storage(
                    "\(plan.name) was deleted, but Restorey couldn't remove \(failures.joined(separator: " or "))")
            }
            return status
        }
    }

    /// Records that the user has saved the plan's recovery details. Until then the plan never runs
    /// on its own.
    public func confirmRecoveryKit(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        _ = try requirePlan(id)
        return try await serialisedWrite {
            var updated = config
            guard let index = updated.plans.firstIndex(where: { $0.id == id }) else { throw AgentError.unknownPlan }
            updated.plans[index].recoveryKitConfirmedAt = now()
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Pauses for `pauseDuration`, after which the plan is due at once, and asks the runner to stop a
    /// run in progress (SIGINT, then SIGKILL; the run ends `.paused`). Allowed while draining.
    public func pause(_ id: UUID) async throws -> AgentStatus {
        try requireLoaded()
        let until = now().addingTimeInterval(Self.pauseDuration)
        let status = try await updateHistory(id) { $0.pausedUntil = until }
        await runner?.interrupt(planID: id, intent: .pause)
        return status
    }

    public func resume(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        return try await updateHistory(id) { $0.pausedUntil = nil }
    }

    /// Changes one plan's history and saves `state.json`, through the write gate. The runner records
    /// every run through this.
    @discardableResult
    func updateHistory(
        _ id: UUID, _ change: @Sendable (inout PlanRunHistory) -> Void
    ) async throws -> AgentStatus {
        _ = try requirePlan(id)
        return try await serialisedWrite {
            _ = try requirePlan(id)
            var state = runState
            change(&state.plans[id, default: PlanRunHistory()])
            try await saveState(state)
            return pushStatus()
        }
    }

    // MARK: Runs (the app's run actions are in AgentState+Runs.swift)

    func requireRunnable(_ id: UUID?) throws {
        try requireMutable()
        if let id { _ = try requirePlan(id) }
    }

    /// Registers an in-flight run. Refused while draining, in the config-error state, for an unknown
    /// plan, a plan being deleted, or a plan already running. Every successful call must be paired with
    /// `endRun`.
    public func beginRun(planID: UUID) throws {
        try requireRunnable(nil)
        let plan = try requirePlan(planID)
        guard !deleting.contains(planID) else { throw AgentError.planDeleting(name: plan.name) }
        guard running[planID] == nil else { throw AgentError.alreadyRunning(name: plan.name) }
        running[planID] = RunProgress()
        pushStatus()
    }

    /// Records the latest progress and "retrying" line for a running plan. Pushed at most every
    /// `progressPushInterval`.
    public func updateRun(planID: UUID, progress: BackupStatus?, retrying: String?) {
        guard running[planID] != nil else { return }
        running[planID] = RunProgress(progress: progress, retrying: retrying)
        let now = now()
        if let last = lastProgressPush, now.timeIntervalSince(last) < Self.progressPushInterval, now >= last {
            return
        }
        lastProgressPush = now
        pushStatus(deliveringAlerts: false)
    }

    public func endRun(planID: UUID) {
        guard running.removeValue(forKey: planID) != nil else { return }
        pushStatus()
        wakeDrainersIfIdle()
    }

    /// Stops new runs and most writes, and returns once no run is in flight and no write is running or
    /// queued. There is deliberately no timeout for that: a long first backup is waited for (spec §8).
    /// Then it waits for the runner's queued check-in pings, for at most `pingBudget` (about the check-in
    /// sender's retry budget), so an exit doesn't drop a `/fail`. Draining is never undone; the agent exits
    /// afterwards.
    /// - Returns: false when the pings were given up on.
    @discardableResult
    public func prepareForRestart(pingBudget: Duration = .seconds(180)) async -> Bool {
        await drain(.restart, pingBudget: pingBudget)
    }

    /// The same drain, for the app's `unregister()` then `register()`: the agent stays up, drained and
    /// refusing every mutating call but `pause`, until `unregister()` stops it. Exiting instead would let
    /// launchd's `KeepAlive` start a fresh agent that `unregister()` could then kill mid-run.
    @discardableResult
    public func prepareForReregistration(pingBudget: Duration = .seconds(180)) async -> Bool {
        await drain(.reregistration, pingBudget: pingBudget)
    }

    private func drain(_ purpose: DrainPurpose, pingBudget: Duration) async -> Bool {
        if drainPurpose != .restart { drainPurpose = purpose }
        isDraining = true
        while !isIdle {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        guard let runner else { return true }
        return await Self.bounded(pingBudget) { await runner.pingsFlushed() } != nil
    }

    /// `work`'s result if it finishes within `budget`, otherwise nil. The work is not cancelled when it
    /// doesn't: it may be stuck in a call that can't be cancelled (another process's IPC, say).
    static func bounded<T: Sendable>(_ budget: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let settled = Mutex(false)
        let timer = Mutex<Task<Void, Never>?>(nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            func settle(_ value: T?) {
                guard settled.withLock({ let was = $0; $0 = true; return !was }) else { return }
                continuation.resume(returning: value)
            }
            timer.withLock {
                $0 = Task {
                    try? await Task.sleep(for: budget)
                    settle(nil)
                }
            }
            Task {
                let value = await work()
                settle(value)
                timer.withLock { $0?.cancel() }
            }
        }
    }

    private var isIdle: Bool { running.isEmpty && !writeInFlight && writeWaiters.isEmpty }

    /// Wakes every drainer; each re-checks `isIdle` and waits again if something is still going on.
    private func wakeDrainersIfIdle() {
        guard isIdle, !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Password and S3 credential helper

    /// True when `id` is a plan in the loaded config.
    public func isConfiguredPlan(_ id: UUID) -> Bool {
        config.plans.contains { $0.id == id }
    }

    /// Records that a helper request for the plan couldn't read its keys. `reason` names the keychain
    /// account and error, never a value. A later failure replaces an earlier one.
    public func noteHelperFailure(planID: UUID, reason: String) {
        helperFailures[planID] = reason
    }

    /// The reason the last helper request for the plan failed, if one did since the last call; clears it.
    public func takeHelperFailure(planID: UUID) -> String? {
        helperFailures.removeValue(forKey: planID)
    }

    // MARK: Helpers

    func requireLoaded() throws {
        if loadError != nil { throw AgentError.configUnavailable }
    }

    /// Loaded and not draining: the gate for every mutating call except `pause`.
    func requireMutable() throws {
        try requireLoaded()
        guard !isDraining else { throw AgentError.draining }
    }

    func requirePlan(_ id: UUID) throws -> Plan {
        guard let plan = config.plans.first(where: { $0.id == id }) else { throw AgentError.unknownPlan }
        return plan
    }

    /// Writes the config and adopts it in memory only once the write succeeded.
    private func saveConfig(_ updated: ConfigFile) async throws {
        do {
            try await configStore.save(updated)
        } catch {
            throw AgentError.storage("Restorey couldn't save config.json: \(error)")
        }
        config = updated
    }

    /// Saves `state.json`; if the save fails, adopts `updated` in memory anyway and rethrows. For the alert
    /// bookkeeping only: a notification already posted must be remembered as posted, or it would be
    /// posted again on every round while the disk is failing.
    func saveStateKeepingInMemory(_ updated: RunState) async throws {
        do {
            try await saveState(updated)
        } catch {
            runState = updated
            throw error
        }
    }

    func saveState(_ updated: RunState) async throws {
        do {
            try await stateStore.save(updated)
        } catch {
            throw AgentError.storage("Restorey couldn't save state.json: \(error)")
        }
        runState = updated
    }

    /// Runs `body` with no other write in progress. Without this, two writes could each read `config`,
    /// suspend on the store, and the second would overwrite the first. The gate is handed directly to the
    /// next waiter, so it is never seen idle between two queued writes.
    func serialisedWrite<T>(_ body: () async throws -> T) async throws -> T {
        if writeInFlight {
            await withCheckedContinuation { writeWaiters.append($0) }
        } else {
            writeInFlight = true
        }
        defer {
            if writeWaiters.isEmpty {
                writeInFlight = false
                wakeDrainersIfIdle()
            } else {
                writeWaiters.removeFirst().resume()
            }
        }
        return try await body()
    }
}

/// Why the app asked the agent to drain.
public enum DrainPurpose: Sendable, Equatable {
    /// An update: the agent exits once drained and launchd starts the new binary.
    case restart
    /// The app will `unregister()` then `register()`: the agent stays up, drained, until it is stopped.
    case reregistration

    /// Whether the agent exits after replying.
    public var exitsAfterwards: Bool { self == .restart }
}
