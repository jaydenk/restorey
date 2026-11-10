import Foundation

/// Why a run did not start. Produced by the conditions gate (Task 8).
/// JSON: `{"type":"onBattery"}`, `{"type":"batteryBelow","percent":20}`,
/// `{"type":"volumeNotMounted","volume":"Backup"}`.
public enum SkipReason: Codable, Sendable, Equatable {
    case onBattery
    case batteryBelow(Int)
    case constrainedNetwork
    case noNetwork
    case volumeNotMounted(String)

    private enum CodingKeys: String, CodingKey { case type, percent, volume }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "onBattery": self = .onBattery
        case "batteryBelow": self = .batteryBelow(try c.decode(Int.self, forKey: .percent))
        case "constrainedNetwork": self = .constrainedNetwork
        case "noNetwork": self = .noNetwork
        case "volumeNotMounted": self = .volumeNotMounted(try c.decode(String.self, forKey: .volume))
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown skip reason \(other)")
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
    /// The agent died or was killed mid-run. Set on recovery (Task 14), never by `classify`.
    case interrupted
    case skipped(SkipReason)
    case failed(exitCode: Int32, reason: String)

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
        case "skipped": self = .skipped(try c.decode(SkipReason.self, forKey: .reason))
        case "failed":
            self = .failed(
                exitCode: try c.decode(Int32.self, forKey: .exitCode),
                reason: try c.decode(String.self, forKey: .reason))
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown run outcome \(other)")
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
/// 0 success, 3 backup finished with unreadable files, 10 repository missing, 11 lock failure,
/// 12 wrong password, 130 interrupted (SIGINT). `exitErrorMessage` is the `exit_error` text.
///
/// A process we interrupted is classified by what we asked for when it exits 130, or when it ignored
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
        return interruptedByUs == .pause ? .paused : .cancelled
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
        return .warning(unreadable: errors.count)
    case 10: return .repositoryMissing
    case 11: return .locked
    case 12: return .wrongPassword
    case 130:
        switch interruptedByUs {
        case .pause?: return .paused
        case .cancel?: return .cancelled
        case nil: break
        }
    case 1:
        if exitErrorMessage?.contains(missingCredentialsMessage) == true { return .credentialsUnavailable }
    default:
        break
    }
    let reason = exitErrorMessage ?? errors.first?.message ?? "restic exited with status \(exitCode)."
    return .failed(exitCode: exitCode, reason: reason)
}
