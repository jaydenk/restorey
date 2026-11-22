import Foundation
import os
import RestoreyCore

/// Everything `PlanRunner` works with. The probe, the environment and the check-in sender are
/// injected so tests can drive them; the agent passes the real ones.
public struct RunnerDependencies: Sendable {
    public var state: AgentState
    public var secrets: any SecretStore
    public var queues: RepositoryQueues
    public var supervisor: SupervisedProcesses
    public var logStore: RunLogStore
    public var checkIn: any CheckInSending
    public var resticExecutable: URL
    /// The agent's own executable, resolved: restic runs it for the password and S3 credentials.
    public var helperExecutable: URL
    /// `<Caches>/<id root>/restic`, passed as `--cache-dir`.
    public var cacheDirectory: URL
    /// Where `CredentialsFile` writes each S3 plan's `s3/<id>.ini`.
    public var credentialsDirectory: URL
    /// restic's `HOME`.
    public var homeDirectory: URL
    /// The `os_log` subsystem for the runner's own problems (`Identity.rootID`).
    public var logSubsystem: String
    public var fdaProbe: @Sendable () -> FDAProbeResult
    public var preflightEnvironment: @Sendable () async -> PreflightEnvironment
    public var now: @Sendable () -> Date
    /// How long restic gets to honour SIGINT before SIGKILL (global constraints: 10 s).
    public var interruptGracePeriod: Duration
    /// Held while each restic step runs, so the Mac doesn't idle-sleep mid-run (spec §8). Nil: none.
    public var sleepPrevention: SleepPrevention?
    /// Writes a line to the agent's own log (`agent.log`) at ERROR, for problems the user may need to find.
    public var agentLog: @Sendable (String) -> Void
    /// Writes a line to `agent.log` at INFO, for something that went as asked but is worth a trace, such as setup's
    /// confirmed removal of earlier snapshots after a backup (Task 14b).
    public var agentInfo: @Sendable (String) -> Void
    /// True once the agent's executable on disk is no longer the one it was started from (an update
    /// replaced the bundle). Checked before every restic step and on every scheduler tick (Ruling R55).
    public var binaryReplaced: @Sendable () -> Bool
    /// Counts the cloud-only files a backup skipped, for the plan's sources and exclusions. Called off the actor, on a
    /// background thread, after a backup that saved the data; nil: not counted, or it gave up. Never throws or
    /// affects the run (the agent passes `CloudOnlySkipped.counter`).
    /// Nil: there is no counter, so nothing was counted. `.gaveUp`: the bound was reached.
    public var cloudOnlySkipped: @Sendable (_ sources: [String], _ exclusions: [String]) -> CloudOnlyCounter.Result?
    /// Seconds the runner waits for the count before carrying on without it, even if the walk is stuck in one system
    /// call. The walk may finish later on its own thread; its result is discarded.
    public var cloudOnlyDeadline: TimeInterval
    /// Finds the items apps mark as not for backup before each backup of a plan that skips them (Task 15c); the agent
    /// passes `SpotlightMarkedItems`. Nil: none are looked for, so none are skipped and nothing is recorded.
    public var markedItems: (any MarkedItemsFinding)?
    /// Seconds the look for marked items may take before the backup carries on without it (`MarkedItemsScan.offPool`).
    public var markedItemsDeadline: TimeInterval
    /// Where each backup's list of marked items is written (`<planID>.txt`, 0600, in a 0700 folder) for restic's
    /// `--exclude-file`, and removed once restic has finished. Leftovers from an agent that died mid-run go at the
    /// next start (`recoverAfterStart`). Defaults to `<credentialsDirectory>/not-for-backup`.
    public var notForBackupDirectory: URL
    /// restic's `--retry-lock` for the maintenance commands (`ResticContext.maintenanceRetryLock`): five minutes;
    /// tests that hold a lock shorten it.
    public var maintenanceRetryLock: String
    /// Follows a link to a local repository for its exclusion (`LinkResolver`: its own thread, a deadline, one
    /// outstanding). Nil from it means only the path as given is excluded.
    public var linkResolver: LinkResolver
    /// Finds the other file systems mounted inside a plan's folders, for a backup with one file system on
    /// (`OtherFileSystems.current`; tests pass their own). Called through `linkResolver.look`, so a volume that
    /// doesn't answer holds up one thread at most and the backup goes ahead without them.
    public var otherFileSystems: @Sendable ([String]) -> [String]
    /// Measures the upload speed of the network the Mac is on, for a Mac-wide limit given as a percentage (the
    /// upload-limit design). Nil: nothing is measured, so a percentage is never resolved to a limit.
    public var speedTester: SpeedTester?

    public init(
        state: AgentState, secrets: any SecretStore, queues: RepositoryQueues, supervisor: SupervisedProcesses,
        logStore: RunLogStore, checkIn: any CheckInSending, resticExecutable: URL, helperExecutable: URL,
        cacheDirectory: URL, credentialsDirectory: URL, homeDirectory: URL, logSubsystem: String,
        fdaProbe: @escaping @Sendable () -> FDAProbeResult,
        preflightEnvironment: @escaping @Sendable () async -> PreflightEnvironment,
        now: @escaping @Sendable () -> Date,
        interruptGracePeriod: Duration = .seconds(10),
        sleepPrevention: SleepPrevention? = nil,
        agentLog: @escaping @Sendable (String) -> Void = { _ in },
        agentInfo: @escaping @Sendable (String) -> Void = { _ in },
        binaryReplaced: @escaping @Sendable () -> Bool = { false },
        cloudOnlySkipped: @escaping @Sendable ([String], [String]) -> CloudOnlyCounter.Result? = { _, _ in nil },
        cloudOnlyDeadline: TimeInterval = CloudOnlyCounter.defaultTimeLimit,
        markedItems: (any MarkedItemsFinding)? = nil,
        markedItemsDeadline: TimeInterval = MarkedNotForBackup.timeLimit,
        notForBackupDirectory: URL? = nil,
        maintenanceRetryLock: String = "5m",
        linkResolver: LinkResolver = .live,
        otherFileSystems: @escaping @Sendable ([String]) -> [String] = OtherFileSystems.current,
        speedTester: SpeedTester? = nil
    ) {
        self.state = state
        self.secrets = secrets
        self.queues = queues
        self.supervisor = supervisor
        self.logStore = logStore
        self.checkIn = checkIn
        self.resticExecutable = resticExecutable
        self.helperExecutable = helperExecutable
        self.cacheDirectory = cacheDirectory
        self.credentialsDirectory = credentialsDirectory
        self.homeDirectory = homeDirectory
        self.logSubsystem = logSubsystem
        self.fdaProbe = fdaProbe
        self.preflightEnvironment = preflightEnvironment
        self.now = now
        self.interruptGracePeriod = interruptGracePeriod
        self.sleepPrevention = sleepPrevention
        self.agentLog = agentLog
        self.agentInfo = agentInfo
        self.binaryReplaced = binaryReplaced
        self.cloudOnlySkipped = cloudOnlySkipped
        self.cloudOnlyDeadline = cloudOnlyDeadline
        self.markedItems = markedItems
        self.markedItemsDeadline = markedItemsDeadline
        self.notForBackupDirectory = notForBackupDirectory
            ?? credentialsDirectory.appendingPathComponent("not-for-backup", isDirectory: true)
        self.maintenanceRetryLock = maintenanceRetryLock
        self.linkResolver = linkResolver
        self.otherFileSystems = otherFileSystems
        self.speedTester = speedTester
    }
}
