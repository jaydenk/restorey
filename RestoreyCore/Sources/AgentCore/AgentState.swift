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

    struct RunProgress {
        var progress: BackupStatus?
        var retrying: String?
    }

    private let configStore: any PayloadStore<ConfigFile>
    private let stateStore: any PayloadStore<RunState>
    let secrets: any SecretStore
    let credentialsDirectory: URL
    /// The plans' run logs, removed with a deleted plan. Nil: nothing to remove (tests without logs).
    let runLogs: RunLogStore?
    let now: @Sendable () -> Date

    var config: ConfigFile
    private(set) var runState: RunState
    let loadError: String?
    /// `config.json` loaded but `state.json` did not: the plans are listed as stopped.
    let onlyStateUnreadable: Bool

    public internal(set) var isDraining = false
    /// Why the agent is draining, once it is. A drain that ends in an exit (a restart, the system stopping
    /// the agent) wins over a re-registration one, and the system stop wins over a restart.
    public internal(set) var drainPurpose: DrainPurpose?
    /// The system asked the agent to exit (launchd's SIGTERM, `stopForSystem`, Ruling R67).
    public internal(set) var isStoppingForSystem = false
    var running: [UUID: RunProgress] = [:]
    /// Plans `deletePlan` has started removing. No run may begin on them.
    var deleting: Set<UUID> = []
    /// Plans whose repository is being measured after an adopt (`beginMeasurement`). Not a run: the plan
    /// stays idle and can back up (its backup waits in the repository's queue), but a drain waits for it
    /// and a delete stops it first.
    /// Registered measurements and credential checks per plan, counted: an adopt's size measurement and a check
    /// can overlap, and the first to end mustn't end the other's registration.
    var measuring: [UUID: Int] = [:]
    /// `deletePlan` callers waiting for a measurement they stopped to end.
    var measuringWaiters: [CheckedContinuation<Void, Never>] = []
    /// `prepareForRestart` callers, woken whenever the agent may have become idle.
    var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// How the agent exits once a restart drain is over, so launchd's `KeepAlive` starts the binary on
    /// disk, and where it says why (`attach(restartExit:log:)`).
    var restartExit: (@Sendable () -> Void)?
    var restartLog: @Sendable (String) -> Void = { _ in }
    /// The agent found its own executable replaced and began a restart drain itself.
    var replacementNoticed = false
    /// The app's restart drains (`restart(reply:)`) not yet replied to: the agent never exits before them.
    var restartRepliesOwed = 0
    /// A restart drain is over, so the agent should exit once no reply is owed.
    var exitWanted = false
    var exited = false

    var writeInFlight = false
    var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Writes waiting their turn behind the one in flight, for tests.
    var queuedWrites: Int { writeWaiters.count }
    /// Follows links where the user acts (`savePlan`); tests attach one they can hold (`attach(linkResolver:)`).
    var linkResolver: LinkResolver = .live

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
    /// The network the Mac was on and its measurement when the runner last looked (`noteUploadSpeed`); nil until it
    /// has. Its `testing` is never read: the status derives it from `speedTestsRunning`.
    var uploadSpeedView: UploadSpeedStatus?
    /// Upload speed tests running now, of any kind (`speedTestBegan`, `noteUploadSpeed(endingTest:)`).
    var speedTestsRunning = 0

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
    var statusSequence: UInt64 = 0

    var observer: (@Sendable (AgentStatus) -> Void)?
    var lastProgressPush: Date?
    /// What each plan looked like in the last push, for `pushStatusIfChanged`.
    var lastPushed: [UUID: PushedPlan] = [:]

    /// The parts of a plan's status that can change with time alone.
    struct PushedPlan: Equatable {
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
            fileURL: directory.appendingPathComponent("config.json", isDirectory: false),
            currentVersion: ConfigMigrations.currentVersion, migrations: ConfigMigrations.migrations)
    }

    /// `upload-speeds.json`, beside `config.json` and `state.json`: the upload speed measured on each network
    /// (`SpeedTester`). A measurement, not a setting, so it is a file of its own.
    public static func uploadSpeedsStore(in directory: URL) -> VersionedStore<UploadSpeedsFile> {
        UploadSpeedsFile.store(in: directory)
    }

    public static func stateStore(in directory: URL) -> VersionedStore<RunState> {
        VersionedStore(
            fileURL: directory.appendingPathComponent("state.json", isDirectory: false),
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

    /// Follows the plan's links through `linkResolver` (its own thread, a deadline, one outstanding) and throws
    /// `invalidPlan` for a source that leads into its local repository. When the file system doesn't answer in time
    /// the save goes ahead on the comparison by path, which has already passed, and the agent log says so.
    func refuseSourcesReachingTheRepositoryThroughLinks(_ plan: Plan) async throws {
        guard let throughLinks = await plan.sourcesInsideRepositoryFollowingLinks(resolver: linkResolver) else {
            agentLog("Couldn’t check where the folders of plan \(plan.id.uuidString) lead: the file system didn’t "
                + "answer, so they were checked as written")
            return
        }
        guard throughLinks.isEmpty else { throw AgentError.invalidPlan(throughLinks) }
    }

    /// Writes the config and adopts it in memory only once the write succeeded.
    func saveConfig(_ updated: ConfigFile) async throws {
        try await writeConfig(updated)
        config = updated
    }

    /// Writes `config.json` without adopting it, for a caller that must change `config` together with other state.
    func writeConfig(_ updated: ConfigFile) async throws {
        do {
            try await configStore.save(updated)
        } catch {
            throw AgentError.storage("Restorey couldn’t save config.json: \(error)")
        }
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

/// What `AgentState.cancel` did: the status and the `CancelOutcome` (`CancelResult` on the wire). The agent's log says so
/// only when something was stopped (final review m7).
public struct CancelReply: Sendable {
    public var status: AgentStatus
    public var outcome: CancelOutcome

    /// This Cancel stopped a run, or dropped the backup Resume queued behind one. False when nothing was running,
    /// or the run was already being stopped (a pause wins).
    public var stoppedARun: Bool { outcome == .stoppedARun }

    public var result: CancelResult { CancelResult(status: status, outcome: outcome) }
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
