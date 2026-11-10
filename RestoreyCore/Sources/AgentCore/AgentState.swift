import Foundation
import RestoreyCore

/// The payload of `config.json` (schema `ConfigMigrations.currentVersion`): `{"plans":[…]}`.
public struct ConfigFile: Codable, Sendable, Equatable {
    public var plans: [Plan]

    public init(plans: [Plan] = []) {
        self.plans = plans
    }
}

/// Why the agent refused a request. `message` is the Australian English sentence the XPC reply carries.
public enum AgentError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `config.json` or `state.json` could not be read; `AgentStatus.configError` says why.
    case configUnavailable
    /// `prepareForRestart` was called; the agent is waiting to exit.
    case draining
    case invalidPlan([PlanValidationError])
    case unknownPlan
    case planRunning(name: String)
    case alreadyRunning(name: String)
    /// A `SavePlanRequest` carried a secret keyed to another plan.
    case foreignSecret
    /// Implemented by a later task (backups, repository creation and adoption arrive with the runner).
    case notYetAvailable
    /// Writing a store, the keychain or a file failed. The text names the step, never a secret.
    case storage(String)
    /// The XPC payload could not be decoded.
    case invalidRequest(String)

    public var message: String {
        switch self {
        case .configUnavailable: "Restorey can't change its settings until the problem with them is fixed"
        case .draining: "Restorey is finishing the current backup before updating the agent"
        case .invalidPlan(let errors):
            errors.map(Self.message(for:)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ". ")
        case .unknownPlan: "There's no plan with that ID"
        case .planRunning(let name): "\(name) is backing up. Wait for it to finish, then delete it"
        case .alreadyRunning(let name): "\(name) is already backing up"
        case .foreignSecret: "A secret in the request belongs to a different plan"
        case .notYetAvailable: "That isn't available in this build of Restorey yet"
        case .storage(let detail): detail
        case .invalidRequest(let detail): "Restorey couldn't read the request: \(detail)"
        }
    }

    public var description: String { message }

    private static func message(for error: PlanValidationError) -> String {
        switch error {
        case .emptyHostLabel: "The host label can't be empty"
        case .noSources: "Choose at least one source folder"
        case .relativeSource: "Source folders must be absolute paths"
        case .intervalTooShort: "Backups can't run more often than every 5 minutes"
        }
    }
}

/// The testable heart of the agent: it owns `config.json`, `state.json` and the plans' keychain
/// secrets (the agent is their only writer), tracks in-flight runs, and builds `AgentStatus`.
///
/// If either file cannot be read when the agent starts (newer schema, corrupt, no migration), the agent
/// enters a config-error state: it reports the problem in `status`, refuses every mutating call and
/// never writes either file, so the user's plans survive (Review Focus 2).
///
/// Calls that write are serialised, so two requests arriving together over XPC can never interleave
/// across the stores' `await`s and lose an update.
public actor AgentState {
    public static let pauseDuration: TimeInterval = 3600
    /// Progress pushes are at most this often; phase changes are always pushed.
    public static let progressPushInterval: TimeInterval = 0.5
    static let stateSchemaVersion = 1

    private struct RunProgress {
        var progress: BackupStatus?
        var retrying: String?
    }

    private let configStore: VersionedStore<ConfigFile>
    private let stateStore: VersionedStore<RunState>
    private let secrets: any SecretStore
    private let credentialsDirectory: URL
    private let now: @Sendable () -> Date

    private var config: ConfigFile
    private var runState: RunState
    private let loadError: String?

    public private(set) var isDraining = false
    private var running: [UUID: RunProgress] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    private var observer: (@Sendable (AgentStatus) -> Void)?
    private var lastProgressPush: Date?

    /// Loads both stores. A load failure is kept as the config error rather than thrown.
    /// - Parameters:
    ///   - credentialsDirectory: where `CredentialsFile` keeps the plans' `s3/<id>.ini` files.
    public init(
        configStore: VersionedStore<ConfigFile>,
        stateStore: VersionedStore<RunState>,
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
            configStore: VersionedStore(
                fileURL: directory.appendingPathComponent("config.json"),
                currentVersion: ConfigMigrations.currentVersion, migrations: ConfigMigrations.migrations),
            stateStore: VersionedStore(
                fileURL: directory.appendingPathComponent("state.json"),
                currentVersion: Self.stateSchemaVersion, migrations: [:]),
            secrets: secrets, credentialsDirectory: directory, now: now, startupError: startupError)
    }

    private init(
        configStore: VersionedStore<ConfigFile>,
        stateStore: VersionedStore<RunState>,
        secrets: any SecretStore,
        credentialsDirectory: URL,
        now: @escaping @Sendable () -> Date,
        startupError: String?
    ) async {
        var loadError = startupError
        var config = ConfigFile()
        var runState = RunState()
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
        self.config = loadError == nil ? config : ConfigFile()
        self.runState = loadError == nil ? runState : RunState()
        self.loadError = loadError
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
        guard loadError == nil else {
            return AgentStatus(plans: [], configError: loadError, fdaMissing: nil, generatedAt: now)
        }
        return AgentStatus(
            plans: config.plans.map { planStatus($0, now: now) }, configError: nil, fdaMissing: nil,
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

    @discardableResult
    private func pushStatus() -> AgentStatus {
        let status = status()
        observer?(status)
        return status
    }

    // MARK: Plans

    /// Validates, writes the secrets, then the config. If a secret cannot be written the config is
    /// left as it was. `recoveryKitConfirmedAt` is agent-owned: a new plan starts unconfirmed and an
    /// existing plan keeps its confirmation, whatever the request says.
    public func savePlan(_ request: SavePlanRequest) async throws -> AgentStatus {
        try await serialisedWrite {
            try requireLoaded()
            guard !isDraining else { throw AgentError.draining }
            let errors = request.plan.validationErrors()
            guard errors.isEmpty else { throw AgentError.invalidPlan(errors) }
            guard request.secrets.allSatisfy({ $0.key.planID == request.plan.id }) else {
                throw AgentError.foreignSecret
            }

            var plan = request.plan
            var updated = config
            if let index = updated.plans.firstIndex(where: { $0.id == plan.id }) {
                plan.recoveryKitConfirmedAt = updated.plans[index].recoveryKitConfirmedAt
                updated.plans[index] = plan
            } else {
                plan.recoveryKitConfirmedAt = nil
                updated.plans.append(plan)
            }

            for entry in request.secrets {
                do {
                    try secrets.write(entry.value, for: entry.key)
                } catch {
                    throw AgentError.storage(
                        "Restorey couldn't save \(entry.key.account) in the Keychain: \(error)")
                }
            }
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Removes the plan from the config, then its secrets, credentials file and history. The
    /// repository is never touched. A running plan cannot be deleted.
    public func deletePlan(_ id: UUID) async throws -> AgentStatus {
        try await serialisedWrite {
            try requireLoaded()
            let plan = try requirePlan(id)
            guard running[id] == nil else { throw AgentError.planRunning(name: plan.name) }

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
        try await serialisedWrite {
            try requireLoaded()
            _ = try requirePlan(id)
            var updated = config
            if let index = updated.plans.firstIndex(where: { $0.id == id }) {
                updated.plans[index].recoveryKitConfirmedAt = now()
            }
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Pauses for `pauseDuration`, after which the plan is due at once. Interrupting a run that is in
    /// progress is the runner's job.
    public func pause(_ id: UUID) async throws -> AgentStatus {
        let until = now().addingTimeInterval(Self.pauseDuration)
        return try await updateHistory(id) { $0.pausedUntil = until }
    }

    public func resume(_ id: UUID) async throws -> AgentStatus {
        try await updateHistory(id) { $0.pausedUntil = nil }
    }

    private func updateHistory(
        _ id: UUID, _ change: (inout PlanRunHistory) -> Void
    ) async throws -> AgentStatus {
        try await serialisedWrite {
            try requireLoaded()
            _ = try requirePlan(id)
            var state = runState
            change(&state.plans[id, default: PlanRunHistory()])
            try await saveState(state)
            return pushStatus()
        }
    }

    // MARK: Runs

    /// Backs up one plan, or every plan when `id` is nil.
    public func backUpNow(_ id: UUID?) async throws -> AgentStatus {
        try requireRunnable(id)
        throw AgentError.notYetAvailable
    }

    /// Runs `restic init` for the plan.
    public func createRepository(_ id: UUID) async throws -> AgentStatus {
        try requireRunnable(id)
        throw AgentError.notYetAvailable
    }

    /// Reads an existing repository's snapshots for every host.
    public func adopt(_ id: UUID) async throws -> AdoptReport {
        try requireRunnable(id)
        throw AgentError.notYetAvailable
    }

    private func requireRunnable(_ id: UUID?) throws {
        try requireLoaded()
        guard !isDraining else { throw AgentError.draining }
        if let id { _ = try requirePlan(id) }
    }

    /// Registers an in-flight run. Refused while draining, in the config-error state, for an unknown
    /// plan, or when the plan is already running. Every successful call must be paired with `endRun`.
    public func beginRun(planID: UUID) throws {
        try requireRunnable(nil)
        let plan = try requirePlan(planID)
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
        pushStatus()
    }

    public func endRun(planID: UUID) {
        guard running.removeValue(forKey: planID) != nil else { return }
        pushStatus()
        if running.isEmpty {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Stops new runs and returns once no run is in flight. There is deliberately no timeout: a long
    /// first backup is waited for (spec §8). Draining is never undone; the agent exits afterwards.
    public func prepareForRestart() async {
        isDraining = true
        guard !running.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    // MARK: Helpers

    private func requireLoaded() throws {
        if loadError != nil { throw AgentError.configUnavailable }
    }

    private func requirePlan(_ id: UUID) throws -> Plan {
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

    private func saveState(_ updated: RunState) async throws {
        do {
            try await stateStore.save(updated)
        } catch {
            throw AgentError.storage("Restorey couldn't save state.json: \(error)")
        }
        runState = updated
    }

    /// Runs `body` with no other write in progress. Without this, two writes could each read `config`,
    /// suspend on the store, and the second would overwrite the first.
    private func serialisedWrite<T>(_ body: () async throws -> T) async throws -> T {
        while writeInFlight {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
        writeInFlight = true
        defer {
            writeInFlight = false
            if !writeWaiters.isEmpty { writeWaiters.removeFirst().resume() }
        }
        return try await body()
    }
}
