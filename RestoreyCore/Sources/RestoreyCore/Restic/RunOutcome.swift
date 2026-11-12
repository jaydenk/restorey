import Foundation

/// Why a run did not start. Produced by the conditions gate (Task 8), and by the runner for a backup
/// that an agent being replaced won't start (`agentUpdating`, Ruling R55).
/// JSON: `{"type":"onBattery"}`, `{"type":"batteryBelow","percent":20}`,
/// `{"type":"volumeNotMounted","volume":"Backup"}`, `{"type":"agentUpdating"}`.
public enum SkipReason: Codable, Sendable, Equatable {
    case onBattery
    case batteryBelow(Int)
    case constrainedNetwork
    case noNetwork
    case volumeNotMounted(String)
    /// The agent was draining before an update (or found its binary replaced), so it started no new
    /// restic step. The next agent runs the backup at once (`nextRunDate`).
    case agentUpdating

    /// The sentence shown for a skipped run, in the menu, run logs and alerts.
    public var summary: String {
        switch self {
        case .onBattery: "Skipped while on battery"
        // No space before the sign (Australian Government Style Manual).
        case .batteryBelow(let percent): "Skipped: battery below \(percent)%"
        case .constrainedNetwork: "Skipped on a low data network"
        case .noNetwork: "Skipped: no network"
        case .volumeNotMounted(let volume): "Skipped: \(volume) isn't connected"
        case .agentUpdating: "Skipped: Restorey was updating"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, percent, volume }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "onBattery": self = .onBattery
        case "batteryBelow": self = .batteryBelow(try c.decode(Int.self, forKey: .percent))
        case "constrainedNetwork": self = .constrainedNetwork
        case "noNetwork": self = .noNetwork
        case "volumeNotMounted": self = .volumeNotMounted(try c.decode(String.self, forKey: .volume))
        case "agentUpdating": self = .agentUpdating
        case let other: throw UnknownCase.error(kind: "skip reason", name: other, in: c, forKey: .type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .onBattery: try c.encode("onBattery", forKey: .type)
        case .batteryBelow(let percent):
            try c.encode("batteryBelow", forKey: .type)
            try c.encode(percent, forKey: .percent)
        case .constrainedNetwork: try c.encode("constrainedNetwork", forKey: .type)
        case .noNetwork: try c.encode("noNetwork", forKey: .type)
        case .volumeNotMounted(let volume):
            try c.encode("volumeNotMounted", forKey: .type)
            try c.encode(volume, forKey: .volume)
        case .agentUpdating: try c.encode("agentUpdating", forKey: .type)
        }
    }
}

/// How a run ended. Drives alerts and the status UI, and is persisted in run records.
/// JSON: `{"type":"success","snapshotID":"…"}` (key omitted when nil), `{"type":"warning","unreadable":3}`,
/// `{"type":"skipped","reason":{…}}`, `{"type":"failed","exitCode":2,"reason":"…"}`, and
/// `{"type":"<case>"}` for the rest.
public enum RunOutcome: Codable, Sendable, Equatable {
    case success(snapshotID: String?)
    /// Backup finished and `--skip-if-unchanged` made no snapshot.
    case unchanged
    /// Backup finished and made a snapshot, but some files could not be read (restic exit 3).
    case warning(unreadable: Int)
    case paused
    case cancelled
    case repositoryMissing
    case wrongPassword
    case credentialsUnavailable
    case locked
    /// The agent died or was killed mid-run without saying why (a crash, `kill -9`): recovery finds the
    /// run still marked in progress. Set on recovery (Task 14), never by `classify`. A failure (R21).
    case interrupted
    /// The system stopped the agent (logout, restart or shutdown: launchd's SIGTERM) and the agent
    /// stopped the run itself, restic removing its own lock (Ruling R67). Not a verdict: no alert, no
    /// check-in ping, and the backup is tried again after the short retry.
    case stoppedBySystem
    case skipped(SkipReason)
    case failed(exitCode: Int32, reason: String)

    /// The `exitCode` of a failure restic never ran for: refused before it started, or restic couldn't
    /// be started at all.
    public static let notStartedExitCode: Int32 = -1

    private enum CodingKeys: String, CodingKey { case type, snapshotID, unreadable, reason, exitCode }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "success": self = .success(snapshotID: try c.decodeIfPresent(String.self, forKey: .snapshotID))
        case "unchanged": self = .unchanged
        case "warning": self = .warning(unreadable: try c.decode(Int.self, forKey: .unreadable))
        case "paused": self = .paused
        case "cancelled": self = .cancelled
        case "repositoryMissing": self = .repositoryMissing
        case "wrongPassword": self = .wrongPassword
        case "credentialsUnavailable": self = .credentialsUnavailable
        case "locked": self = .locked
        case "interrupted": self = .interrupted
        case "stoppedBySystem": self = .stoppedBySystem
        case "skipped": self = .skipped(try c.decode(SkipReason.self, forKey: .reason))
        case "failed":
            self = .failed(
                exitCode: try c.decode(Int32.self, forKey: .exitCode),
                reason: try c.decode(String.self, forKey: .reason))
        case let other: throw UnknownCase.error(kind: "run outcome", name: other, in: c, forKey: .type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let snapshotID):
            try c.encode("success", forKey: .type)
            try c.encodeIfPresent(snapshotID, forKey: .snapshotID)
        case .unchanged: try c.encode("unchanged", forKey: .type)
        case .warning(let unreadable):
            try c.encode("warning", forKey: .type)
            try c.encode(unreadable, forKey: .unreadable)
        case .paused: try c.encode("paused", forKey: .type)
        case .cancelled: try c.encode("cancelled", forKey: .type)
        case .repositoryMissing: try c.encode("repositoryMissing", forKey: .type)
        case .wrongPassword: try c.encode("wrongPassword", forKey: .type)
        case .credentialsUnavailable: try c.encode("credentialsUnavailable", forKey: .type)
        case .locked: try c.encode("locked", forKey: .type)
        case .interrupted: try c.encode("interrupted", forKey: .type)
        case .stoppedBySystem: try c.encode("stoppedBySystem", forKey: .type)
        case .skipped(let reason):
            try c.encode("skipped", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .failed(let exitCode, let reason):
            try c.encode("failed", forKey: .type)
            try c.encode(exitCode, forKey: .exitCode)
            try c.encode(reason, forKey: .reason)
        }
    }
}

/// What we asked restic to do when we sent it SIGINT.
public enum InterruptIntent: Sendable, Equatable {
    case pause
    case cancel
    /// The system is stopping the agent (launchd's SIGTERM at logout, restart or shutdown, Ruling R67).
    case systemStop

    /// How a run we stopped this way ends.
    public var outcome: RunOutcome {
        switch self {
        case .pause: .paused
        case .cancel: .cancelled
        case .systemStop: .stoppedBySystem
        }
    }
}

/// The error a Codable enum throws for a case name this build doesn't know, which a newer build wrote.
/// It is a `DecodingError.dataCorrupted` whose `underlyingError` is an `UnknownCase`, so a caller that
/// can do without the value (a history record) can tell it from real corruption and drop just that value.
public struct UnknownCase: Error, CustomStringConvertible {
    public var kind: String
    public var name: String
    public var description: String { "Unknown \(kind) \(name)" }

    static func error<K: CodingKey>(
        kind: String, name: String, in container: KeyedDecodingContainer<K>, forKey key: K
    ) -> DecodingError {
        let unknown = UnknownCase(kind: kind, name: name)
        return .dataCorrupted(DecodingError.Context(
            codingPath: container.codingPath + [key], debugDescription: unknown.description, underlyingError: unknown))
    }

    /// True when `error` is one of these, so the value was written by a newer build.
    public static func isUnknownCase(_ error: any Error) -> Bool {
        guard case DecodingError.dataCorrupted(let context) = error else { return false }
        return context.underlyingError is UnknownCase
    }
}

/// What started a run.
public enum RunTrigger: String, Codable, Sendable, Equatable {
    case scheduled
    case catchUp
    case manual
    case retry
}

/// One finished run, kept in `PlanRunHistory.recent`.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var planID: UUID
    public var operation: ResticOperation
    public var trigger: RunTrigger
    public var startedAt: Date
    public var endedAt: Date
    public var outcome: RunOutcome
    public var summary: BackupSummary?
    /// Path of the run's log file, relative to the log directory. Empty when the run never reached
    /// restic (skipped, refused before it started) or its log could not be created.
    public var logFile: String
    /// Lines that could not be written to the run's log (`RunLogWriter.droppedLineCount`). When the log
    /// could not be created at all, every line the run tried to write counts. Omitted from JSON when 0,
    /// and 0 for records written before it existed.
    public var droppedLogLines: Int

    public init(
        id: UUID, planID: UUID, operation: ResticOperation, trigger: RunTrigger,
        startedAt: Date, endedAt: Date, outcome: RunOutcome, summary: BackupSummary?, logFile: String,
        droppedLogLines: Int = 0
    ) {
        self.id = id
        self.planID = planID
        self.operation = operation
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.summary = summary
        self.logFile = logFile
        self.droppedLogLines = droppedLogLines
    }

    private enum CodingKeys: String, CodingKey {
        case id, planID, operation, trigger, startedAt, endedAt, outcome, summary, logFile, droppedLogLines
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        planID = try c.decode(UUID.self, forKey: .planID)
        operation = try c.decode(ResticOperation.self, forKey: .operation)
        trigger = try c.decode(RunTrigger.self, forKey: .trigger)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        outcome = try c.decode(RunOutcome.self, forKey: .outcome)
        summary = try c.decodeIfPresent(BackupSummary.self, forKey: .summary)
        logFile = try c.decode(String.self, forKey: .logFile)
        droppedLogLines = try c.decodeIfPresent(Int.self, forKey: .droppedLogLines) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(planID, forKey: .planID)
        try c.encode(operation, forKey: .operation)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(logFile, forKey: .logFile)
        if droppedLogLines != 0 { try c.encode(droppedLogLines, forKey: .droppedLogLines) }
    }
}

/// The message restic prints when the `credential_process` helper fails (Task 1 finding).
private let missingCredentialsMessage = "s3.getCredentials: no credentials found"

/// Maps a finished restic process to an outcome. Exit codes are restic's documented ones:
/// 0 success, 3 backup finished with unreadable files (for `forget`: a snapshot couldn't be removed), 10 repository missing, 11 lock failure,
/// 12 wrong password, 130 interrupted (SIGINT). `exitErrorMessage` is the `exit_error` text.
///
/// A process we interrupted is classified by what we asked for (`InterruptIntent.outcome`) when it exits 130, or when it ignored
/// SIGINT and was then killed by the SIGKILL that `ResticProcess` itself sent (`killedByUs`). Any
/// other death by signal (SIGSEGV, SIGABRT, a SIGKILL from elsewhere) is a failure, interrupted or not.
///
/// Exit 0 depends on the operation: a backup must have reported a summary (with a snapshot ID it is a
/// success, without one it is unchanged, and with no summary at all it failed, because a backup that
/// exits 0 without saying what it did cannot be trusted). Every other operation is a plain success.
public func classify(
    operation: ResticOperation,
    exitCode: Int32,
    interruptedByUs: InterruptIntent?,
    terminatedBySignal: Int32? = nil,
    killedByUs: Bool = false,
    summary: BackupSummary?,
    errors: [ResticItemError],
    exitErrorMessage: String?
) -> RunOutcome {
    if let interruptedByUs, killedByUs, terminatedBySignal == SIGKILL {
        return interruptedByUs.outcome
    }
    switch exitCode {
    case 0:
        guard case .backup = operation else { return .success(snapshotID: nil) }
        guard let summary else {
            return .failed(exitCode: 0, reason: "restic finished without reporting a backup summary")
        }
        if let snapshotID = summary.snapshotID { return .success(snapshotID: snapshotID) }
        return .unchanged
    case 3:
        // Exit 3 means "some source data couldn't be read" only for a backup. For `forget` it means a
        // snapshot couldn't be removed (restic 0.19.1's documented exit codes), which is a failure of that
        // step, not unreadable files (final review M9). Any other operation has no documented 3.
        switch operation {
        case .backup: return .warning(unreadable: errors.count)
        case .forget:
            return .failed(exitCode: 3, reason: exitErrorMessage ?? errors.first?.message
                ?? "restic couldn't remove every snapshot it was asked to forget")
        default: break
        }
    case 10: return .repositoryMissing
    case 11: return .locked
    case 12: return .wrongPassword
    case 130:
        // restic exits 130 for SIGINT and SIGTERM alike (0.19.1 cmd/restic/cleanup.go cancels its
        // context on either; main.go maps context.Canceled to 130), so a restic the system signalled
        // directly while we were stopping it for the system reads the same.
        if let interruptedByUs { return interruptedByUs.outcome }
    case 1:
        if exitErrorMessage?.contains(missingCredentialsMessage) == true { return .credentialsUnavailable }
    default:
        break
    }
    let reason = exitErrorMessage ?? errors.first?.message ?? "restic exited with status \(exitCode)."
    return .failed(exitCode: exitCode, reason: reason)
}
