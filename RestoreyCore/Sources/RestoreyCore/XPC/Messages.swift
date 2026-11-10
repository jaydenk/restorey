import Foundation

/// The JSON coding for every XPC payload: the same as `config.json`, so dates are UTC ISO 8601 with
/// millisecond precision (`2027-01-15T08:00:00.123Z`) and keys are sorted.
public enum XPCCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try VersionedStore<HelloRequest>.makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try VersionedStore<HelloRequest>.makeDecoder().decode(type, from: data)
    }
}

// MARK: Handshake

/// The app's half of the version handshake (spec §8).
public struct HelloRequest: Codable, Sendable, Equatable {
    public var appVersion: String
    public var appBuild: String

    public init(appVersion: String, appBuild: String) {
        self.appVersion = appVersion
        self.appBuild = appBuild
    }
}

public struct HelloReply: Codable, Sendable, Equatable {
    public var agentVersion: String
    public var agentBuild: String
    /// Where the running agent binary is. The app checks it is inside its own bundle.
    public var executablePath: String
    /// True once `prepareForRestart` has been called: the agent starts no more runs.
    public var draining: Bool
    /// Nil until the user has been asked.
    public var notificationsAuthorised: Bool?

    public init(
        agentVersion: String, agentBuild: String, executablePath: String, draining: Bool,
        notificationsAuthorised: Bool?
    ) {
        self.agentVersion = agentVersion
        self.agentBuild = agentBuild
        self.executablePath = executablePath
        self.draining = draining
        self.notificationsAuthorised = notificationsAuthorised
    }
}

// MARK: Status

/// Everything the app shows, in one snapshot. Sent as the reply to `status` and to every mutating
/// call, and pushed through `AgentClientXPC.statusChanged`.
public struct AgentStatus: Codable, Sendable, Equatable {
    public var plans: [PlanStatus]
    /// Set when `config.json` or `state.json` could not be read (newer schema, corrupt, no migration).
    /// The agent then runs nothing and changes nothing until the file is fixed (Review Focus 2).
    public var configError: String?
    /// Nil until the Full Disk Access probe has run.
    public var fdaMissing: Bool?
    public var generatedAt: Date

    public init(plans: [PlanStatus], configError: String?, fdaMissing: Bool?, generatedAt: Date) {
        self.plans = plans
        self.configError = configError
        self.fdaMissing = fdaMissing
        self.generatedAt = generatedAt
    }
}

public struct PlanStatus: Codable, Sendable, Equatable {
    public var plan: Plan
    public var phase: PlanPhase
    public var lastRecord: RunRecord?
    /// Nil when the plan will not run on its own (stopped, invalid, or no confirmed recovery kit).
    public var nextRunAt: Date?
    /// Sorted by raw value.
    public var alerts: [AlertCondition]

    public init(plan: Plan, phase: PlanPhase, lastRecord: RunRecord?, nextRunAt: Date?, alerts: [AlertCondition]) {
        self.plan = plan
        self.phase = phase
        self.lastRecord = lastRecord
        self.nextRunAt = nextRunAt
        self.alerts = alerts
    }
}

/// What a plan is doing now.
/// JSON: `{"type":"idle"}`, `{"type":"running","progress":{…},"retrying":"…"}` (either key omitted
/// when nil), `{"type":"paused","until":"…"}`, `{"type":"stopped","reason":"…"}`,
/// `{"type":"skipped","reason":{…}}`.
public enum PlanPhase: Codable, Sendable, Equatable {
    case idle
    /// The latest restic progress, if any has arrived, and the most recent restic stderr line that
    /// contains "retrying" (restic retries an unreachable backend for up to 15 minutes), so the UI
    /// can say "Can't reach the repository — retrying" (Ruling R14).
    case running(BackupStatus?, retrying: String?)
    case paused(until: Date)
    case stopped(reason: String)
    /// The last attempt was skipped by a pre-run condition.
    case skipped(SkipReason)

    private enum CodingKeys: String, CodingKey { case type, progress, retrying, until, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "idle": self = .idle
        case "running":
            self = .running(
                try c.decodeIfPresent(BackupStatus.self, forKey: .progress),
                retrying: try c.decodeIfPresent(String.self, forKey: .retrying))
        case "paused": self = .paused(until: try c.decode(Date.self, forKey: .until))
        case "stopped": self = .stopped(reason: try c.decode(String.self, forKey: .reason))
        case "skipped": self = .skipped(try c.decode(SkipReason.self, forKey: .reason))
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown plan phase \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle: try c.encode("idle", forKey: .type)
        case .running(let progress, let retrying):
            try c.encode("running", forKey: .type)
            try c.encodeIfPresent(progress, forKey: .progress)
            try c.encodeIfPresent(retrying, forKey: .retrying)
        case .paused(let until):
            try c.encode("paused", forKey: .type)
            try c.encode(until, forKey: .until)
        case .stopped(let reason):
            try c.encode("stopped", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .skipped(let reason):
            try c.encode("skipped", forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }
}

// MARK: Saving a plan

/// One secret for the agent to put in the keychain. Its descriptions and mirror never include the
/// value, so a request can be logged or dumped safely.
public struct SecretEntry: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var key: SecretKey
    public var value: String

    public init(key: SecretKey, value: String) {
        self.key = key
        self.value = value
    }

    public var description: String { "SecretEntry(\(key.account), value: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["key": key.account, "value": "<redacted>"], displayStyle: .struct)
    }
}

/// `savePlan`'s request: the plan for `config.json` and its secrets for the keychain.
public struct SavePlanRequest: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public var plan: Plan
    public var secrets: [SecretEntry]

    public init(plan: Plan, secrets: [SecretEntry]) {
        self.plan = plan
        self.secrets = secrets
    }

    public var description: String {
        "SavePlanRequest(plan: \(plan.id.uuidString) \"\(plan.name)\", secrets: [\(secrets.map(\.key.account).joined(separator: ", "))])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["plan": plan, "secrets": secrets.map(\.key.account)], displayStyle: .struct)
    }
}

// MARK: Other replies

/// What `adopt` found in an existing repository (spec §5.2).
public struct AdoptReport: Codable, Sendable, Equatable {
    public var hosts: [String]
    public var latestPathsForHost: [String]
    public var snapshotCount: Int

    public init(hosts: [String], latestPathsForHost: [String], snapshotCount: Int) {
        self.hosts = hosts
        self.latestPathsForHost = latestPathsForHost
        self.snapshotCount = snapshotCount
    }
}

/// `prepareForRestart`'s reply, `{"drained":true}`, sent only once no run is in flight.
public struct DrainReply: Codable, Sendable, Equatable {
    public var drained: Bool

    public init(drained: Bool) {
        self.drained = drained
    }
}

public struct NotificationPermissionReply: Codable, Sendable, Equatable {
    public var granted: Bool

    public init(granted: Bool) {
        self.granted = granted
    }
}
