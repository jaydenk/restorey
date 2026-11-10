import Foundation

/// One line of restic's `--json` output, as the process supervisor sees it.
///
/// Which stream carries which message (captured from restic 0.19.1, see the fixtures):
/// `status`, `summary` (backup and check) and `verbose_status` arrive on stdout; `error` and
/// `exit_error` arrive on stderr. The parser does not care which stream a line came from.
public enum ResticMessage: Sendable, Equatable {
    case status(BackupStatus)
    /// A backup summary, from `backup --json`.
    case summary(BackupSummary)
    case error(ResticItemError)
    case exitError(code: Int, message: String)
    /// A `check --json` summary. Its shape differs from the backup summary: see `ResticMessageParser`.
    case checkSummary(CheckSummary)
    /// Per-file detail printed by `backup --verbose`. Carries nothing the app uses.
    case verboseStatus
    /// A well-formed message of a type this version does not model, for example `initialized`.
    case unknown(type: String)
    /// Not JSON, truncated, not an object, or a known type whose fields do not fit. The line is kept
    /// so the supervisor can still write it to the run log.
    case unparseable(String)
}

/// Progress of a running backup (`message_type: "status"`). Restic omits fields that are zero or not
/// yet known (for example `seconds_remaining` and `seconds_elapsed`), so only absence is tolerated.
/// The parser reads restic's snake_case keys itself; the synthesised `Codable` (camelCase keys) is the
/// agent's own wire format, used in `PlanPhase.running` over XPC.
public struct BackupStatus: Codable, Sendable, Equatable {
    public var percentDone: Double
    public var totalFiles: Int
    public var filesDone: Int
    public var totalBytes: Int
    public var bytesDone: Int
    public var secondsRemaining: Int?
    public var errorCount: Int
    public var currentFiles: [String]

    public init(
        percentDone: Double = 0, totalFiles: Int = 0, filesDone: Int = 0, totalBytes: Int = 0,
        bytesDone: Int = 0, secondsRemaining: Int? = nil, errorCount: Int = 0, currentFiles: [String] = []
    ) {
        self.percentDone = percentDone
        self.totalFiles = totalFiles
        self.filesDone = filesDone
        self.totalBytes = totalBytes
        self.bytesDone = bytesDone
        self.secondsRemaining = secondsRemaining
        self.errorCount = errorCount
        self.currentFiles = currentFiles
    }
}

/// The result of a backup (`message_type: "summary"` with `files_new`). Persisted in run records, so
/// the JSON keys are restic's own names. Counts a restic version omits decode as 0 rather than
/// failing: a malformed summary on a run that exited 0 would otherwise look like "no summary".
/// `snapshotID` is nil when `--skip-if-unchanged` skipped the snapshot.
public struct BackupSummary: Codable, Sendable, Equatable {
    public var filesNew: Int
    public var filesChanged: Int
    public var filesUnmodified: Int
    public var dataAdded: Int
    public var dataAddedPacked: Int
    public var totalFilesProcessed: Int
    public var totalBytesProcessed: Int
    /// Seconds.
    public var totalDuration: Double
    public var backupStart: Date?
    public var backupEnd: Date?
    public var snapshotID: String?

    public init(
        filesNew: Int = 0, filesChanged: Int = 0, filesUnmodified: Int = 0, dataAdded: Int = 0,
        dataAddedPacked: Int = 0, totalFilesProcessed: Int = 0, totalBytesProcessed: Int = 0,
        totalDuration: Double = 0, backupStart: Date? = nil, backupEnd: Date? = nil, snapshotID: String? = nil
    ) {
        self.filesNew = filesNew
        self.filesChanged = filesChanged
        self.filesUnmodified = filesUnmodified
        self.dataAdded = dataAdded
        self.dataAddedPacked = dataAddedPacked
        self.totalFilesProcessed = totalFilesProcessed
        self.totalBytesProcessed = totalBytesProcessed
        self.totalDuration = totalDuration
        self.backupStart = backupStart
        self.backupEnd = backupEnd
        self.snapshotID = snapshotID
    }

    private enum CodingKeys: String, CodingKey {
        case filesNew = "files_new"
        case filesChanged = "files_changed"
        case filesUnmodified = "files_unmodified"
        case dataAdded = "data_added"
        case dataAddedPacked = "data_added_packed"
        case totalFilesProcessed = "total_files_processed"
        case totalBytesProcessed = "total_bytes_processed"
        case totalDuration = "total_duration"
        case backupStart = "backup_start"
        case backupEnd = "backup_end"
        case snapshotID = "snapshot_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filesNew = try c.decodeIfPresent(Int.self, forKey: .filesNew) ?? 0
        filesChanged = try c.decodeIfPresent(Int.self, forKey: .filesChanged) ?? 0
        filesUnmodified = try c.decodeIfPresent(Int.self, forKey: .filesUnmodified) ?? 0
        dataAdded = try c.decodeIfPresent(Int.self, forKey: .dataAdded) ?? 0
        dataAddedPacked = try c.decodeIfPresent(Int.self, forKey: .dataAddedPacked) ?? 0
        totalFilesProcessed = try c.decodeIfPresent(Int.self, forKey: .totalFilesProcessed) ?? 0
        totalBytesProcessed = try c.decodeIfPresent(Int.self, forKey: .totalBytesProcessed) ?? 0
        totalDuration = try c.decodeIfPresent(Double.self, forKey: .totalDuration) ?? 0
        // A malformed timestamp must not discard the counts and snapshot ID.
        backupStart = try? c.decodeIfPresent(Date.self, forKey: .backupStart)
        backupEnd = try? c.decodeIfPresent(Date.self, forKey: .backupEnd)
        snapshotID = try c.decodeIfPresent(String.self, forKey: .snapshotID)
    }
}

/// The result of `check --json`: `{"message_type":"summary","num_errors":0,"broken_packs":null,
/// "suggest_repair_index":false,"suggest_prune":false}`.
public struct CheckSummary: Sendable, Equatable {
    public var numErrors: Int
    /// Pack IDs, null when none are broken.
    public var brokenPacks: [String]?
    public var suggestRepairIndex: Bool
    public var suggestPrune: Bool

    public init(numErrors: Int, brokenPacks: [String]?, suggestRepairIndex: Bool, suggestPrune: Bool) {
        self.numErrors = numErrors
        self.brokenPacks = brokenPacks
        self.suggestRepairIndex = suggestRepairIndex
        self.suggestPrune = suggestPrune
    }
}

/// A non-fatal problem reported on stderr. During a backup it names the file (`during` and `item`
/// are set). `check` reports a flat message with neither.
public struct ResticItemError: Sendable, Equatable {
    public var message: String
    public var during: String?
    public var item: String?

    public init(message: String, during: String? = nil, item: String? = nil) {
        self.message = message
        self.during = during
        self.item = item
    }
}

public enum ResticMessageParser {
    /// Parses one line. Never throws or traps: anything that is not a recognisable message is
    /// returned as `.unparseable` or `.unknown`.
    ///
    /// Telling the two `summary` messages apart: a summary carrying any backup marker (`files_new`,
    /// `snapshot_id`, `total_files_processed`, `data_added`) is a backup summary, even if `num_errors`
    /// is also present. Only a summary with `num_errors` and no backup marker is a check summary.
    /// A summary with neither, or with a `num_errors` that is not an integer and no backup marker,
    /// is `.unparseable`: it is never turned into an all-zero backup summary.
    public static func parse(_ line: String) -> ResticMessage {
        let data = Data(line.utf8)
        guard let probe = try? decoder.decode(Probe.self, from: data) else { return .unparseable(line) }
        do {
            switch probe.messageType {
            case "status":
                return .status(try decoder.decode(StatusWire.self, from: data).value)
            case "summary":
                if probe.hasBackupMarker {
                    return .summary(try decoder.decode(BackupSummary.self, from: data))
                }
                if probe.hasNumErrors {
                    return .checkSummary(try decoder.decode(CheckSummaryWire.self, from: data).value)
                }
                return .unparseable(line)
            case "error":
                return .error(try decoder.decode(ErrorWire.self, from: data).value)
            case "exit_error":
                let wire = try decoder.decode(ExitErrorWire.self, from: data)
                return .exitError(code: wire.code, message: wire.message)
            case "verbose_status":
                return .verboseStatus
            case let other:
                return .unknown(type: other)
            }
        } catch {
            return .unparseable(line)
        }
    }

    // MARK: Wire types

    private struct Probe: Decodable {
        let messageType: String
        let hasBackupMarker: Bool
        /// The key is present with a non-null value (its type is checked when the check summary decodes).
        let hasNumErrors: Bool
        private enum CodingKeys: String, CodingKey {
            case messageType = "message_type", numErrors = "num_errors"
            case filesNew = "files_new", snapshotID = "snapshot_id"
            case totalFilesProcessed = "total_files_processed", dataAdded = "data_added"
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messageType = try c.decode(String.self, forKey: .messageType)
            func has(_ key: CodingKeys) -> Bool { c.contains(key) && ((try? c.decodeNil(forKey: key)) == false) }
            hasBackupMarker = has(.filesNew) || has(.snapshotID) || has(.totalFilesProcessed) || has(.dataAdded)
            hasNumErrors = has(.numErrors)
        }
    }

    private struct StatusWire: Decodable {
        let value: BackupStatus
        private enum CodingKeys: String, CodingKey {
            case percentDone = "percent_done", totalFiles = "total_files", filesDone = "files_done"
            case totalBytes = "total_bytes", bytesDone = "bytes_done", secondsRemaining = "seconds_remaining"
            case errorCount = "error_count", currentFiles = "current_files"
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = BackupStatus(
                percentDone: try c.decodeIfPresent(Double.self, forKey: .percentDone) ?? 0,
                totalFiles: try c.decodeIfPresent(Int.self, forKey: .totalFiles) ?? 0,
                filesDone: try c.decodeIfPresent(Int.self, forKey: .filesDone) ?? 0,
                totalBytes: try c.decodeIfPresent(Int.self, forKey: .totalBytes) ?? 0,
                bytesDone: try c.decodeIfPresent(Int.self, forKey: .bytesDone) ?? 0,
                secondsRemaining: try c.decodeIfPresent(Int.self, forKey: .secondsRemaining),
                errorCount: try c.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0,
                currentFiles: try c.decodeIfPresent([String].self, forKey: .currentFiles) ?? []
            )
        }
    }

    private struct CheckSummaryWire: Decodable {
        let value: CheckSummary
        private enum CodingKeys: String, CodingKey {
            case numErrors = "num_errors", brokenPacks = "broken_packs"
            case suggestRepairIndex = "suggest_repair_index", suggestPrune = "suggest_prune"
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = CheckSummary(
                numErrors: try c.decode(Int.self, forKey: .numErrors),
                brokenPacks: try c.decodeIfPresent([String].self, forKey: .brokenPacks),
                suggestRepairIndex: try c.decodeIfPresent(Bool.self, forKey: .suggestRepairIndex) ?? false,
                suggestPrune: try c.decodeIfPresent(Bool.self, forKey: .suggestPrune) ?? false
            )
        }
    }

    /// Backup errors nest the text (`{"error":{"message":…},"during":…,"item":…}`); check errors
    /// put it at the top level (`{"message":…}`).
    private struct ErrorWire: Decodable {
        let value: ResticItemError
        private enum CodingKeys: String, CodingKey { case error, message, during, item }
        private struct Nested: Decodable { let message: String }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let message: String
            if let nested = try c.decodeIfPresent(Nested.self, forKey: .error) {
                message = nested.message
            } else {
                message = try c.decode(String.self, forKey: .message)
            }
            value = ResticItemError(
                message: message,
                during: try c.decodeIfPresent(String.self, forKey: .during),
                item: try c.decodeIfPresent(String.self, forKey: .item)
            )
        }
    }

    private struct ExitErrorWire: Decodable {
        let code: Int
        let message: String
    }

    // MARK: Decoder

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(string)"))
            }
            return date
        }
        return decoder
    }()

    /// restic prints local time with an offset and microseconds (`2026-11-10T18:33:42.939137+10:30`).
    /// Accepts any fractional length, and `Z`.
    private static func parseDate(_ string: String) -> Date? {
        let styles = [
            Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true),
            Date.ISO8601FormatStyle(timeZoneSeparator: .colon),
        ]
        for style in styles {
            if let date = try? Date(string, strategy: style) { return date }
        }
        return nil
    }
}
