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
/// While draining (`prepareForRestart`, or `restartForReplacedBinary` when the agent finds its own
/// executable replaced), every mutating call except `pause` and `cancel` is refused. Both stay allowed so the user
/// can still stop a long first backup; the next agent honours `pausedUntil`. The runner starts no new
/// restic step while draining: the step in flight finishes, nothing after it (Ruling R55).
public actor AgentState {
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
    /// The plans' run logs, removed with a deleted plan. Nil: nothing to remove (tests without logs).
    private let runLogs: RunLogStore?
    let now: @Sendable () -> Date

    private(set) var config: ConfigFile
    private(set) var runState: RunState
    let loadError: String?
    /// `config.json` loaded but `state.json` did not: the plans are listed as stopped.
    private let onlyStateUnreadable: Bool

    public private(set) var isDraining = false
    /// Why the agent is draining, once it is. A drain that ends in an exit (a restart, the system stopping
    /// the agent) wins over a re-registration one, and the system stop wins over a restart.
    public private(set) var drainPurpose: DrainPurpose?
    /// The system asked the agent to exit (launchd's SIGTERM, `stopForSystem`, Ruling R67).
    public private(set) var isStoppingForSystem = false
    private var running: [UUID: RunProgress] = [:]
    /// Plans `deletePlan` has started removing. No run may begin on them.
    private var deleting: Set<UUID> = []
    /// Plans whose repository is being measured after an adopt (`beginMeasurement`). Not a run: the plan
    /// stays idle and can back up (its backup waits in the repository's queue), but a drain waits for it
    /// and a delete stops it first.
    /// Registered measurements and credential checks per plan, counted: an adopt's size measurement and a check
    /// can overlap, and the first to end mustn't end the other's registration.
    private var measuring: [UUID: Int] = [:]
    /// `deletePlan` callers waiting for a measurement they stopped to end.
    private var measuringWaiters: [CheckedContinuation<Void, Never>] = []
    /// `prepareForRestart` callers, woken whenever the agent may have become idle.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// How the agent exits once a restart drain is over, so launchd's `KeepAlive` starts the binary on
    /// disk, and where it says why (`attach(restartExit:log:)`).
    private var restartExit: (@Sendable () -> Void)?
    private var restartLog: @Sendable (String) -> Void = { _ in }
    /// The agent found its own executable replaced and began a restart drain itself.
    private var replacementNoticed = false
    /// The app's restart drains (`restart(reply:)`) not yet replied to: the agent never exits before them.
    private var restartRepliesOwed = 0
    /// A restart drain is over, so the agent should exit once no reply is owed.
    private var exitWanted = false
    private var exited = false

    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Writes a line to the agent's own log (`agent.log`) for the run actions it refuses
    /// (`attach(agentLog:)`), so a Back Up Now that did nothing leaves a trace (final review M5).
    var agentLog: @Sendable (String) -> Void = { _ in }

    /// Per plan, why the last helper request failed to read the keychain (the runner reports it).
    private var helperFailures: [UUID: String] = [:]
    /// Credentials being checked by `probeRepository(_:candidates:)` (`CandidateSecrets`).
    public nonisolated let candidates = CandidateSecrets()

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

    /// This process's statuses, in the order they were built (`AgentStatus.supersedes`). The run is also sent in
    /// every hello, so the app can tell this process from the one before it (Ruling R76).
    let statusRun = UUID()
    private var statusSequence: UInt64 = 0

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
    ///   - runLogs: the run logs `deletePlan` removes with a plan; the runner's store.
    public init(
        configStore: any PayloadStore<ConfigFile>,
        stateStore: any PayloadStore<RunState>,
        secrets: any SecretStore,
        credentialsDirectory: URL,
        runLogs: RunLogStore? = nil,
        now: @escaping @Sendable () -> Date
    ) async {
        await self.init(
            configStore: configStore, stateStore: stateStore, secrets: secrets,
            credentialsDirectory: credentialsDirectory, runLogs: runLogs, now: now, startupError: nil)
    }

    /// The agent's layout: `config.json`, `state.json` and the credentials files all in `directory`
    /// (`Identity.applicationSupportDirectory()`), which is created with mode 0700.
    public init(
        directory: URL, secrets: any SecretStore, runLogs: RunLogStore? = nil, now: @escaping @Sendable () -> Date
    ) async {
        var startupError: String?
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // createDirectory leaves the mode of an existing folder alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            startupError = "Restorey can’t create its settings folder \(directory.path): \(error.localizedDescription)"
        }
        await self.init(
            configStore: Self.configStore(in: directory), stateStore: Self.stateStore(in: directory),
            secrets: secrets, credentialsDirectory: directory, runLogs: runLogs, now: now,
            startupError: startupError)
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
        runLogs: RunLogStore?,
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
        self.runLogs = runLogs
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
            return "\(file) can’t be read: \(underlying). \(leftAlone)"
        case .missingMigration(let from)?:
            return "\(file) uses schema \(from), which this version of Restorey can’t upgrade. \(leftAlone)"
        case .migrationFailed(let from, let underlying)?:
            return "\(file) couldn’t be upgraded from schema \(from): \(underlying). \(leftAlone)"
        case nil:
            return "\(file) can’t be read: \(error.localizedDescription). \(leftAlone)"
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
        statusSequence += 1
        if let loadError {
            // Without history nothing can be scheduled, but the user still sees their plans.
            let plans = onlyStateUnreadable
                ? config.plans.map {
                    PlanStatus(plan: $0, phase: .stopped(reason: loadError), lastRecord: nil, nextRunAt: nil,
                               alerts: [.configurationError])
                }
                : []
            return AgentStatus(
                plans: plans, configError: loadError, fdaMissing: nil, generatedAt: now,
                agentRun: statusRun, sequence: statusSequence, network: onlyStateUnreadable ? config.network : nil)
        }
        return AgentStatus(
            plans: config.plans.map { planStatus($0, now: now) }, configError: nil, fdaMissing: fdaMissing,
            generatedAt: now, agentRun: statusRun, sequence: statusSequence, network: config.network)
    }

    /// The Mac-wide network rules the preflight applies (Ruling P2-6).
    var networkSettings: NetworkSettings { config.network }

    private func planStatus(_ plan: Plan, now: Date) -> PlanStatus {
        let history = runState.plans[plan.id] ?? PlanRunHistory()
        let phase: PlanPhase
        if let run = running[plan.id] {
            phase = .running(run.progress, retrying: run.retrying)
        } else if let reason = history.stopReason(for: plan) {
            phase = .stopped(reason: reason)
        } else if let until = history.pausedUntil, until > now {
            phase = .paused(until: min(until, now.addingTimeInterval(PauseLength.longest.seconds)))
        } else if case .skipped(let reason)? = history.recent.first?.outcome {
            phase = .skipped(reason)
        } else {
            phase = .idle
        }
        let next = nextRunDate(plan: plan, history: history, now: now)
        var raised = activeConditions(history: history, plan: plan, now: now).union(history.activeAlerts.keys)
        // A probe since the run that raised it found access granted: the alert is gone now, not after the
        // next delivery round clears it from `activeAlerts` (or never, with no notifier attached).
        if !fullDiskAccessAlertStands(history: history, fullDiskAccessMissing: fdaMissing) {
            raised.remove(.fullDiskAccessMissing)
        }
        let alerts = raised.sorted { $0.rawValue < $1.rawValue }
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: history.recent.first,
            nextRunAt: next == .distantFuture ? nil : next, alerts: alerts,
            lastBackup: history.lastBackupRecord, repositorySize: history.repositorySize,
            setupState: PlanSetupState(plan: plan),
            latestBackupRecord: history.recent.first { $0.operation == .backup },
            latestBackupVerdict: history.recent.first { $0.operation == .backup && $0.outcome.isVerdict },
            earlierRemovalProblem: history.pendingEarlierRemoval == nil
                ? nil : history.pendingEarlierRemovalFailures?.noticeReason)
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

    /// A pause can only be `PauseLength.longest` (a day). One that ends later than that from now was set before
    /// the clock went backwards, and would last as long again as the clock moved: it is cut back to
    /// a day from now and saved, so it then runs out normally (final review M2). The scheduler's
    /// tick calls this. A save that fails is tried again at the next tick.
    public func clampStretchedPauses() async {
        let now = now()
        let limit = now.addingTimeInterval(PauseLength.longest.seconds)
        let stretched = runState.plans.filter { _, history in (history.pausedUntil ?? .distantPast) > limit }.map(\.key)
        for id in stretched where config.plans.contains(where: { $0.id == id }) {
            _ = try? await updateHistory(id) { history in
                if let until = history.pausedUntil, until > limit { history.pausedUntil = limit }
            }
            restartLog("The clock went backwards during a pause, so plan \(id.uuidString) is now paused for a day from now")
        }
    }

    // MARK: Plans

    /// Validates, writes the secrets, then the config. If a secret write or the config write fails,
    /// every submitted secret is put back as it was (new keys deleted) and the config is unchanged.
    ///
    /// `recoveryKitConfirmedAt` is agent-owned. A new plan starts unconfirmed. An existing plan keeps its
    /// confirmation only if the repository is the same and every submitted secret equals the keychain's
    /// current value; otherwise the recovery details the user saved no longer match, so it is cleared.
    /// `setupCompletedAt` and `offMacNoteDismissed` are agent-owned too: a new plan starts without them and
    /// an existing plan keeps the stored values, whatever the request says (Ruling P2-3). Only
    /// `confirmRecoveryKit` and `dismissOffMacNote` set them.
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
        // Validation compares paths only (it runs on every status); here, where the user acts, a source that reaches
        // the repository through a link is refused too. Following links reads the disk, so it runs off the actor, and
        // the agent may have started draining meanwhile (final review I1).
        let throughLinks = await request.plan.sourcesInsideRepositoryFollowingLinks()
        guard throughLinks.isEmpty else { throw AgentError.invalidPlan(throughLinks) }
        try requireMutable()
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
            plan.normaliseFileTypeExclusions()
            var updated = config
            var credentialsChanged = false
            let checkInChanged = !plan.hasCheckInURL || planSecrets.changesValue(of: .checkInURL(plan.id))
            if let index = updated.plans.firstIndex(where: { $0.id == plan.id }) {
                let stored = updated.plans[index]
                // The recovery kit holds the address, the password, the backend keys and the host label its
                // restore commands pass as `--host`: a change to any of them needs a new kit before backups carry
                // on. The check-in URL isn't needed to restore (product spec §7), so changing it from the Alerts
                // tab doesn't pause backups.
                // Only a new address or secret can cure a stop (a wrong password, a missing repository); a new
                // label can't, so it doesn't clear one.
                credentialsChanged = stored.repository != plan.repository
                    || planSecrets.changesAnyValue(excluding: [checkInKey])
                let kitStillHolds = !credentialsChanged && stored.hostLabel == plan.hostLabel
                plan.recoveryKitConfirmedAt = kitStillHolds ? stored.recoveryKitConfirmedAt : nil
                plan.setupCompletedAt = stored.setupCompletedAt
                plan.offMacNoteDismissed = stored.offMacNoteDismissed
                updated.plans[index] = plan
            } else {
                plan.recoveryKitConfirmedAt = nil
                plan.setupCompletedAt = nil
                plan.offMacNoteDismissed = false
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
                    throw AgentError.storage("\(plan.name) was saved, but Restorey couldn’t clear \(what): \(detail)")
                }
            }
            return pushStatus()
        }
    }

    /// Removes the plan from the config, then its secrets, credentials file, history and run logs. The
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
        // A measurement after an adopt is stopped rather than refusing the delete (setup's Cancel deletes the
        // plan it just adopted). restic has `interruptGracePeriod` to stop; its record is written before the
        // plan goes. One still waiting in the queue finds the plan gone and doesn't start.
        if measuring[id] != nil {
            await runner?.stopMeasurement(planID: id)
            while measuring[id] != nil { await withCheckedContinuation { measuringWaiters.append($0) } }
        }

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
            // Gone now rather than at the 400-day prune: they would only be found by browsing the folder.
            if let runLogs {
                do { try await runLogs.removePlan(id) } catch { failures.append("its run logs (\(error.localizedDescription))") }
            }
            let status = pushStatus()
            if !failures.isEmpty {
                throw AgentError.storage(
                    "\(plan.name) was deleted, but Restorey couldn’t remove \(failures.joined(separator: " or "))")
            }
            return status
        }
    }

    /// Records that the user has saved the plan's recovery details. Until then the plan never runs
    /// on its own. The first confirmation also finishes setup (`setupCompletedAt`, Ruling P2-3).
    public func confirmRecoveryKit(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        _ = try requirePlan(id)
        return try await serialisedWrite {
            var updated = config
            guard let index = updated.plans.firstIndex(where: { $0.id == id }) else { throw AgentError.unknownPlan }
            let now = now()
            updated.plans[index].recoveryKitConfirmedAt = now
            if updated.plans[index].setupCompletedAt == nil { updated.plans[index].setupCompletedAt = now }
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Records that the user dismissed the plan's "No off-Mac monitoring" note. It stays dismissed: no saved
    /// plan can bring it back.
    public func dismissOffMacNote(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        _ = try requirePlan(id)
        return try await serialisedWrite {
            var updated = config
            guard let index = updated.plans.firstIndex(where: { $0.id == id }) else { throw AgentError.unknownPlan }
            updated.plans[index].offMacNoteDismissed = true
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// The run records of one plan, or of every plan when `id` is nil, newest (by end) first (Ruling P2-4):
    /// each plan's `recent`, and its `lastBackupRecord` when that has fallen out of `recent`. Answered while
    /// draining; refused in the config-error state.
    public func history(_ id: UUID?) throws -> [RunRecord] {
        try requireLoaded()
        let plans = try id.map { [try requirePlan($0)] } ?? config.plans
        let records = plans.flatMap { plan -> [RunRecord] in
            let history = runState.plans[plan.id] ?? PlanRunHistory()
            guard let last = history.lastBackupRecord, !history.recent.contains(where: { $0.id == last.id }) else {
                return history.recent
            }
            return history.recent + [last]
        }
        // Stable: records that ended together keep their plan's order.
        return records.enumerated()
            .sorted { a, b in
                a.element.endedAt != b.element.endedAt ? a.element.endedAt > b.element.endedAt : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The plan and every secret the agent holds for it, for the recovery kit (Ruling P2-5): the repository
    /// password; an S3 plan's two keys or a raw plan's environment values, in the plan's order; and the
    /// check-in URL when the plan has one. The XPC listener serves only the signed app, which holds the
    /// reply only while the kit is open. A secret that can't be read, or is missing, refuses the kit (a kit
    /// without it would fail the user in a disaster); the error names the Keychain account, never a value.
    /// Read inside the write gate, so a save in progress can't pair one plan's secrets with another version.
    public func recoveryKit(_ id: UUID) async throws -> RecoveryKitSecrets {
        try requireLoaded()
        _ = try requirePlan(id)
        return try await serialisedWrite {
            let plan = try requirePlan(id)
            var keys: [SecretKey] = [.repositoryPassword(id)]
            switch plan.repository {
            case .s3: keys += [.s3AccessKeyID(id), .s3SecretAccessKey(id)]
            case .raw(_, let names): keys += names.map { .environment(id, name: $0) }
            }
            if plan.hasCheckInURL { keys.append(.checkInURL(id)) }
            let entries = try keys.map { key in
                let value: String?
                do {
                    value = try secrets.read(key)
                } catch {
                    throw AgentError.storage("Restorey couldn’t read \(key.account) from the Keychain: \(error)")
                }
                guard let value else {
                    throw AgentError.storage("\(key.account) isn’t in the Keychain, so the recovery kit would be incomplete")
                }
                return SecretEntry(key: key, value: value)
            }
            return RecoveryKitSecrets(plan: plan, secrets: entries)
        }
    }

    /// Saves the Mac-wide network rules (Ruling P2-6) beside the plans in `config.json`, Wi-Fi names
    /// trimmed, and pushes the status. Settings with any problem are refused with every reason and nothing
    /// is saved (Review Focus 5). They apply from the next restic step: a backup already uploading keeps
    /// the limit it started with, since restic can't change it mid-run (Ruling P2-7).
    public func saveNetworkSettings(_ settings: NetworkSettings) async throws -> AgentStatus {
        try requireMutable()
        let errors = settings.validationErrors()
        guard errors.isEmpty else { throw AgentError.invalidNetworkSettings(errors) }
        return try await serialisedWrite {
            var updated = config
            updated.network = settings.normalised()
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Pauses for `length`, after which the plan is due at once, and asks the runner to stop a
    /// run in progress (SIGINT, then SIGKILL; the run ends `.paused`). Allowed while draining.
    public func pause(_ id: UUID, for length: PauseLength) async throws -> AgentStatus {
        try requireLoaded()
        let until = now().addingTimeInterval(length.seconds)
        let status = try await updateHistory(id) { $0.pausedUntil = until }
        await runner?.interrupt(planID: id, intent: .pause)
        return status
    }

    /// Stops the plan's run in progress, this run only: the schedule carries on, so nothing is saved and
    /// `pausedUntil` is left alone. The run ends `.cancelled`: no ping, no failure alert, no maintenance
    /// after it, and the next backup falls at its normal time (not the short retry). With no run in progress
    /// the status comes back unchanged. A run a pause is already stopping keeps the pause (`handle.request`
    /// returns nil once an intent is set). Allowed while draining, like `pause`, since it only stops work.
    /// `stoppedARun` says whether this Cancel stopped anything, for the agent's log; the app gets the status alone.
    public func cancel(_ id: UUID) async throws -> CancelReply {
        try requireLoaded()
        _ = try requirePlan(id)
        let stopped = await runner?.cancel(planID: id) ?? false
        return CancelReply(status: status(), stoppedARun: stopped)
    }

    /// Clears the plan's pause. When it was paused (`pausedUntil` still in the future), Resume also starts
    /// a fresh backup at once (spec §3, Ruling R59), through Back Up Now, so the pre-run conditions and
    /// the recovery-kit refusal are exactly Back Up Now's: a skip for battery or network is a fine
    /// outcome, and a refusal is thrown after the pause has been cleared. A run still stopping for the
    /// pause isn't "already backing up": the fresh backup starts as soon as it has ended (Ruling R62). A stopped plan
    /// (`stoppedReason`) has its pause cleared and starts nothing: it waits for its repository or secrets
    /// to be fixed, as the scheduler does. A plan that wasn't paused only returns the status. The pause
    /// running out on its own is the scheduler's catch-up run, not this.
    public func resume(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        let start = try await serialisedWrite {
            _ = try requirePlan(id)
            var state = runState
            let history = state.plans[id] ?? PlanRunHistory()
            let wasPaused = history.pausedUntil.map { $0 > now() } ?? false
            state.plans[id, default: PlanRunHistory()].pausedUntil = nil
            try await saveState(state)
            pushStatus()
            return wasPaused && history.stoppedReason == nil
        }
        guard start else { return status() }
        try requireRunnable(id)
        return try await requireRunner().backUpNow(id, afterPausedRun: true).status
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

    /// Registers the measurement after an adopt (`PlanRunner`), as it reaches its turn in the queue.
    /// Refused while draining, in the config-error state, for an unknown plan or one being deleted.
    func beginMeasurement(planID: UUID) throws {
        try requireRunnable(planID)
        let plan = try requirePlan(planID)
        guard !deleting.contains(planID) else { throw AgentError.planDeleting(name: plan.name) }
        measuring[planID, default: 0] += 1
    }

    func isMeasuring(_ planID: UUID) -> Bool { measuring[planID] != nil }

    /// Ends one registration; the plan counts as measuring until the last ends.
    func endMeasurement(planID: UUID) {
        guard let count = measuring[planID] else { return }
        measuring[planID] = count > 1 ? count - 1 : nil
        guard count == 1 else { return }
        let waiters = measuringWaiters
        measuringWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        wakeDrainersIfIdle()
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
    public func prepareForRestart(pingBudget: Duration = drainPingBudget) async -> Bool {
        await drain(.restart, pingBudget: pingBudget)
    }

    /// The app's restart: `prepareForRestart`, then `reply` with its result, then the restart exit, once
    /// every restart drain asked for has been replied to. An agent that began a restart drain itself
    /// (`restartForReplacedBinary`) waits for this reply before exiting, so it is never lost.
    public func restart(pingBudget: Duration = drainPingBudget, reply: @Sendable (Bool) -> Void) async {
        restartRepliesOwed += 1
        let flushed = await prepareForRestart(pingBudget: pingBudget)
        reply(flushed)
        restartRepliesOwed -= 1
        exitWanted = true
        exitIfDone()
    }

    /// Called once at startup with where the refused run actions are logged (`agent.log`).
    public func attach(agentLog: @escaping @Sendable (String) -> Void) {
        self.agentLog = agentLog
    }

    /// Called once at startup with how the agent exits for a restart and where it logs why.
    public func attach(restartExit: @escaping @Sendable () -> Void, log: @escaping @Sendable (String) -> Void) {
        self.restartExit = restartExit
        restartLog = log
    }

    /// The agent's executable on disk is no longer the one it was started from (an update replaced the
    /// bundle): drain for a restart on the agent's own initiative, then exit so launchd starts the new
    /// binary (Ruling R55). New runs are refused from now on; the restic step in flight finishes. Only
    /// the first call does anything.
    public func restartForReplacedBinary(pingBudget: Duration = drainPingBudget) {
        guard !replacementNoticed else { return }
        replacementNoticed = true
        if drainPurpose != .systemStop { drainPurpose = .restart }
        isDraining = true
        restartLog(
            "This agent's executable was replaced by an update: finishing the restic step in progress, then exiting so launchd starts the new one")
        Task {
            if !(await drain(.restart, pingBudget: pingBudget)) {
                restartLog(Self.pingsGivenUp(after: pingBudget))
            }
            exitWanted = true
            exitIfDone()
        }
    }

    /// How long a drain waits for the queued check-in pings: about the sender's retry budget (170 s).
    public static let drainPingBudget: Duration = .seconds(180)

    /// The log line when a drain stopped waiting for pings after `budget`.
    public static func pingsGivenUp(after budget: Duration) -> String {
        let seconds = Int(budget.components.seconds)
        let length = seconds % 60 == 0 && seconds >= 60
            ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")"
            : "\(seconds) second\(seconds == 1 ? "" : "s")"
        return "Gave up waiting for check-in pings after \(length); some may not have been sent"
    }

    private func exitIfDone() {
        // Once the system is stopping the agent, `stopForSystem` owns the exit and its deadline.
        guard exitWanted, restartRepliesOwed == 0, !exited, !isStoppingForSystem, let restartExit else { return }
        exited = true
        if replacementNoticed { restartLog("Exiting so launchd starts the agent's replaced executable") }
        restartExit()
    }

    /// The same drain, for the app's `unregister()` then `register()`: the agent stays up, drained and
    /// refusing every mutating call but `pause` and `cancel`, until `unregister()` stops it. Exiting instead would let
    /// launchd's `KeepAlive` start a fresh agent that `unregister()` could then kill mid-run.
    ///
    /// Refused with `restarting` while a restart drain is under way (the app's, or the agent's own for a
    /// replaced executable), also when one began during this wait: the agent will exit on its own, and the
    /// app's `unregister()` would then meet the fresh agent launchd starts, perhaps mid-backup.
    @discardableResult
    public func prepareForReregistration(pingBudget: Duration = drainPingBudget) async throws -> Bool {
        guard drainPurpose?.exitsAfterwards != true else { throw AgentError.restarting }
        let flushed = await drain(.reregistration, pingBudget: pingBudget)
        guard drainPurpose?.exitsAfterwards != true else { throw AgentError.restarting }
        return flushed
    }

    // MARK: The system stopping the agent (Ruling R67)

    /// The whole of `stopForSystem`, from SIGTERM to the exit: well under launchd's exit timeout, which is
    /// 5 s for a LaunchAgent on macOS 27 (`launchctl print gui/<uid>/<label>` reports "exit timeout = 5";
    /// launchd.plist(5) `ExitTimeOut` calls the default system-defined), after which launchd sends SIGKILL.
    public static let systemStopBudget: Duration = .milliseconds(4_000)
    /// How long restic gets to honour our SIGINT before SIGKILL when the system is stopping the agent. An
    /// honoured SIGINT took under a second in the alpha (Pause stopped restic in 0.8 s).
    public static let systemStopInterruptGrace: Duration = .milliseconds(2_500)
    /// How much of the budget is kept for the queued check-in pings.
    static let systemStopPingShare: Duration = .milliseconds(500)

    /// launchd is stopping the agent (logout, restart or shutdown). That is routine, not a failure: no new
    /// restic step or mutating call is accepted from now on, each run in flight is interrupted with
    /// `.systemStop` (restic gets SIGINT, removes its own lock and the run is committed `.stoppedBySystem`:
    /// no alert, no ping, retried after the short retry), and the state and queued pings are given the
    /// rest of `budget`. Runs that haven't ended by then are left to recovery, which records them
    /// `.interrupted`.
    ///
    /// - Parameter runner: the runner, which may not be attached yet (recovery's unlocks run before it is).
    /// - Returns: true when the caller should exit now; false when it is already exiting (a restart exit
    ///   is on its way) or another call is handling the stop, so the agent never exits twice.
    public func stopForSystem(
        runner: PlanRunner?, budget: Duration = systemStopBudget,
        interruptGrace: Duration = systemStopInterruptGrace
    ) async -> Bool {
        guard !isStoppingForSystem, !exited else { return false }
        isStoppingForSystem = true
        isDraining = true
        drainPurpose = .systemStop
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        restartLog("The system is stopping the agent (logout, restart or shutdown): stopping any restic in progress, then exiting")
        let runner = runner ?? self.runner
        await runner?.interruptAll(.systemStop, killAfter: interruptGrace)

        let idleBudget = max(deadline - clock.now - Self.systemStopPingShare, .zero)
        if await Self.bounded(idleBudget, { await self.waitUntilIdle() }) == nil {
            restartLog("A run hadn't ended when the agent had to exit; its next start records it as interrupted")
        }
        if let runner, await Self.bounded(max(deadline - clock.now, .zero), { await runner.pingsFlushed() }) == nil {
            restartLog("Exiting before every queued check-in ping was sent")
        }
        // A restart exit that fired meanwhile has the process on its way out already.
        guard !exited else { return false }
        exited = true
        restartLog("Exiting because the system asked the agent to stop")
        return true
    }

    private func waitUntilIdle() async {
        while !isIdle {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    private func drain(_ purpose: DrainPurpose, pingBudget: Duration) async -> Bool {
        if drainPurpose?.exitsAfterwards != true { drainPurpose = purpose }
        isDraining = true
        while !isIdle {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        guard let runner else { return true }
        return await Self.bounded(pingBudget) { await runner.pingsFlushed() } != nil
    }

    /// How late a `bounded` budget may end.
    static let boundedTimerTolerance: Duration = .milliseconds(50)

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
                    // An explicit tolerance, as for restic's SIGKILL timer: with none, the system may fire
                    // the timer late to coalesce wake-ups (measured at about 5% late), eating into the
                    // system stop's margin under launchd's exit timeout.
                    try? await Task.sleep(for: budget, tolerance: boundedTimerTolerance)
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

    private var isIdle: Bool { running.isEmpty && measuring.isEmpty && !writeInFlight && writeWaiters.isEmpty }

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

    /// Loaded and not draining: the gate for every mutating call except `pause` and `cancel`.
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
            throw AgentError.storage("Restorey couldn’t save config.json: \(error)")
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
            throw AgentError.storage("Restorey couldn’t save state.json: \(error)")
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
    /// launchd's SIGTERM (logout, restart, shutdown): runs are interrupted and the agent exits (R67).
    case systemStop

    /// Whether the agent exits afterwards.
    public var exitsAfterwards: Bool { self != .reregistration }
}

/// What `AgentState.cancel` did. The XPC reply is the status alone; whether a run was stopped is for the agent's log,
/// which says so only when something was (final review m7).
public struct CancelReply: Sendable {
    public var status: AgentStatus
    /// This Cancel stopped a run, or dropped the backup Resume queued behind one. False when nothing was running,
    /// or the run was already being stopped (a pause wins).
    public var stoppedARun: Bool
}

extension PlanRunHistory {
    /// Why the plan won't back up until something is changed: the stop the agent recorded (a wrong password, a missing
    /// repository), or else settings that fail validation, which only a plan saved by an earlier version can have
    /// (final review I2: v0.1 allowed a source inside the plan's own repository). Nil when nothing stops it. The
    /// status reports it as the phase (`stopped`), and `AlertContent` names it in the settings alert.
    func stopReason(for plan: Plan) -> String? {
        if let stoppedReason { return stoppedReason }
        let errors = plan.validationErrors()
        return errors.isEmpty ? nil : AgentError.invalidPlan(errors).message
    }
}
