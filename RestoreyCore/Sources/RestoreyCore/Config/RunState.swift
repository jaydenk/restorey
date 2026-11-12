import Foundation

/// Which alerts are currently raised for a plan. Task 9 decides when each is raised and cleared.
/// Raw values are the JSON keys of `PlanRunHistory.activeAlerts`.
public enum AlertCondition: String, Codable, Sendable, Hashable, CaseIterable {
    case backupFailed
    case checkFailed
    /// The check-in service answered a ping with a 4xx, so it won't alert anyone if backups stop.
    /// Cleared by the plan's next 2xx.
    case checkInRejected
    case configurationError
    case fullDiskAccessMissing
    case noRecentSuccess
    case notificationsOff
}

/// A string-keyed dictionary needs `CodingKeyRepresentable`, otherwise `[AlertCondition: …]` would
/// encode as a flat array of alternating keys and values.
extension AlertCondition: CodingKeyRepresentable {
    public var codingKey: any CodingKey { AlertKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct AlertKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Notification bookkeeping for one raised alert.
public struct AlertNotificationState: Codable, Sendable, Equatable {
    public var raisedAt: Date
    public var lastNotifiedAt: Date?
    public var count: Int

    public init(raisedAt: Date, lastNotifiedAt: Date?, count: Int) {
        self.raisedAt = raisedAt
        self.lastNotifiedAt = lastNotifiedAt
        self.count = count
    }
}

/// The repository's size as `restic stats --mode raw-data` last measured it (Ruling P2-9).
/// JSON: `{"bytes":…,"measuredAt":"…"}`.
public struct RepositorySize: Codable, Sendable, Equatable {
    public var bytes: Int64
    public var measuredAt: Date

    public init(bytes: Int64, measuredAt: Date) {
        self.bytes = bytes
        self.measuredAt = measuredAt
    }
}

/// What the agent remembers about one plan between launches.
public struct PlanRunHistory: Codable, Sendable, Equatable {
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var lastSnapshotAt: Date?
    public var lastForgetAt: Date?
    public var lastPruneAt: Date?
    public var lastCheckAt: Date?
    /// A record that was started but not finished; recovered as `.interrupted` on launch.
    public var runningRecordID: UUID?
    /// The record `runningRecordID` names, as it should read if the agent dies before the step ends:
    /// outcome `.interrupted`, with its real operation, start time and log file. Set and cleared with
    /// `runningRecordID`. Nil in state written before it existed; recovery then rebuilds what it can.
    public var runningRecord: RunRecord?
    /// Newest first, at most `recentLimit` records. Add with `record(_:)`.
    public var recent: [RunRecord]
    public var activeAlerts: [AlertCondition: AlertNotificationState]
    public var stoppedReason: String?
    public var pausedUntil: Date?
    /// Nil until the repository has been measured, and in state written before it existed.
    public var repositorySize: RepositorySize?
    /// The newest backup that saved the data (`savedData`), kept apart from `recent` so a run of skips or
    /// failures longer than `recentLimit` can't push it out. Set by `record(_:)`. State written before it
    /// existed decodes it from `recent`.
    public var lastBackupRecord: RunRecord?

    public static let recentLimit = 50

    /// Puts `record` at the front of `recent` and drops the oldest beyond `recentLimit`. A backup that saved
    /// the data also becomes `lastBackupRecord`.
    public mutating func record(_ record: RunRecord) {
        if Self.savedData(record) { lastBackupRecord = record }
        recent.insert(record, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// A backup whose outcome is success, unchanged or warning (Ruling P2-4): a skip, failure, pause or
    /// maintenance step doesn't count.
    public static func savedData(_ record: RunRecord) -> Bool {
        guard record.operation == .backup else { return false }
        switch record.outcome {
        case .success, .unchanged, .warning: return true
        default: return false
        }
    }

    public init() {
        recent = []
        activeAlerts = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case lastSuccessAt, lastAttemptAt, lastSnapshotAt, lastForgetAt, lastPruneAt, lastCheckAt
        case runningRecordID, runningRecord, recent, activeAlerts, stoppedReason, pausedUntil, repositorySize
        case lastBackupRecord
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSnapshotAt = try c.decodeIfPresent(Date.self, forKey: .lastSnapshotAt)
        lastForgetAt = try c.decodeIfPresent(Date.self, forKey: .lastForgetAt)
        lastPruneAt = try c.decodeIfPresent(Date.self, forKey: .lastPruneAt)
        lastCheckAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        runningRecordID = try c.decodeIfPresent(UUID.self, forKey: .runningRecordID)
        // A record whose outcome, skip reason or operation is a case only a newer build knows is dropped,
        // not fatal, so a downgrade keeps the rest of the history loadable (as for alert keys below). Real
        // corruption still fails the file. A dropped in-progress record is rebuilt by recovery from its ID.
        do {
            runningRecord = try c.decodeIfPresent(RunRecord.self, forKey: .runningRecord)
        } catch where UnknownCase.isUnknownCase(error) {
            runningRecord = nil
        }
        recent = try c.decodeIfPresent([KnownRecord].self, forKey: .recent)?.compactMap(\.record) ?? []
        // Through string keys, so a condition from a newer build is dropped rather than failing the whole
        // file: a downgrade must not turn state.json into the load-error state (Ruling R48).
        let alerts = try c.decodeIfPresent([String: AlertNotificationState].self, forKey: .activeAlerts) ?? [:]
        activeAlerts = Dictionary(uniqueKeysWithValues: alerts.compactMap { key, state in
            AlertCondition(rawValue: key).map { ($0, state) }
        })
        stoppedReason = try c.decodeIfPresent(String.self, forKey: .stoppedReason)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        repositorySize = try c.decodeIfPresent(RepositorySize.self, forKey: .repositorySize)
        // Dropped like `runningRecord` if it names a case this build doesn't know; then, as in state written
        // before the field existed, the newest such record still in `recent` stands in.
        var lastBackup: RunRecord?
        do {
            lastBackup = try c.decodeIfPresent(RunRecord.self, forKey: .lastBackupRecord)
        } catch where UnknownCase.isUnknownCase(error) {
            lastBackup = nil
        }
        lastBackupRecord = lastBackup ?? recent.first(where: Self.savedData)
    }
}

/// A `RunRecord`, or nil when it names a case this build doesn't know (`UnknownCase`).
private struct KnownRecord: Decodable {
    var record: RunRecord?

    init(from decoder: any Decoder) throws {
        do {
            record = try RunRecord(from: decoder)
        } catch where UnknownCase.isUnknownCase(error) {
            record = nil
        }
    }
}

/// The payload of `state.json` (schema version 1), stored through `VersionedStore`.
/// JSON: `{"plans":{"<plan UUID>":{…}}}`. The plan IDs are explicit string keys: `[UUID: …]` would
/// otherwise encode as an array.
public struct RunState: Codable, Sendable, Equatable {
    public var plans: [UUID: PlanRunHistory]

    public init(plans: [UUID: PlanRunHistory] = [:]) {
        self.plans = plans
    }

    private enum CodingKeys: String, CodingKey { case plans }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: PlanRunHistory].self, forKey: .plans) ?? [:]
        var plans: [UUID: PlanRunHistory] = [:]
        for (key, history) in raw {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .plans, in: c, debugDescription: "Plan key \(key) is not a UUID")
            }
            plans[id] = history
        }
        self.plans = plans
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: plans.map { ($0.key.uuidString, $0.value) }), forKey: .plans)
    }
}
