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
    /// `ExecutableFingerprint` of the agent's binary when it started. Nil from agents older than fix
    /// round 3, which the app treats as replaced.
    public var executableFingerprint: String?
    /// Whether the agent may use Location Services, which macOS requires before it reveals the Wi-Fi
    /// network's name: nil until the user has been asked, and from an agent older than Task 3.
    public var locationAuthorised: Bool?
    /// Whether Location Services is on for the whole Mac (System Settings → Privacy & Security → Location
    /// Services), as the agent last read it off its main thread: with it off no app sees the Wi-Fi name, and
    /// macOS can leave the agent's own authorisation undecided. Nil until read, and from an agent older than Task 15.
    public var locationServicesEnabled: Bool?
    /// The same `agentRun` the agent stamps on its statuses. A new one means the agent was relaunched, so
    /// statuses from the run before are stale (Ruling R76). Nil from an agent older than Task 8.
    public var agentRun: UUID?

    public init(
        agentVersion: String, agentBuild: String, executablePath: String, draining: Bool,
        notificationsAuthorised: Bool?, executableFingerprint: String? = nil, locationAuthorised: Bool? = nil,
        locationServicesEnabled: Bool? = nil, agentRun: UUID? = nil
    ) {
        self.agentVersion = agentVersion
        self.agentBuild = agentBuild
        self.executablePath = executablePath
        self.draining = draining
        self.notificationsAuthorised = notificationsAuthorised
        self.executableFingerprint = executableFingerprint
        self.locationAuthorised = locationAuthorised
        self.locationServicesEnabled = locationServicesEnabled
        self.agentRun = agentRun
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
    /// For display only: wall-clock time, which can go backwards. Ordering uses `agentRun` and `sequence`.
    public var generatedAt: Date
    /// Identifies the agent process that built this status (a new one each launch). Nil from an agent
    /// older than the sequence number (final review M1).
    public var agentRun: UUID?
    /// Counts up with every status one agent process builds, so the app can order pushes and replies
    /// without trusting the clock.
    public var sequence: UInt64?
    /// The Mac-wide network rules from `config.json`. Nil when `config.json` couldn't be read, and from an
    /// agent older than schema 3.
    public var network: NetworkSettings?

    public init(
        plans: [PlanStatus], configError: String?, fdaMissing: Bool?, generatedAt: Date,
        agentRun: UUID? = nil, sequence: UInt64? = nil, network: NetworkSettings? = nil
    ) {
        self.plans = plans
        self.configError = configError
        self.fdaMissing = fdaMissing
        self.generatedAt = generatedAt
        self.agentRun = agentRun
        self.sequence = sequence
        self.network = network
    }

    /// Whether the app should show `self` in place of `current`: a status from another agent process (a
    /// restart) always, otherwise only one built no earlier, by `sequence`. A clock that moved backwards
    /// therefore can't freeze the menu (final review M1). Without sequence numbers (an older agent), by
    /// `generatedAt` as before.
    public func supersedes(_ current: AgentStatus?) -> Bool {
        guard let current else { return true }
        if let run = agentRun, let currentRun = current.agentRun, let sequence, let currentSequence = current.sequence {
            return run != currentRun || sequence >= currentSequence
        }
        return generatedAt >= current.generatedAt
    }
}

public struct PlanStatus: Codable, Sendable, Equatable {
    public var plan: Plan
    public var phase: PlanPhase
    /// The newest record of any kind: a backup, a skip, or a maintenance step such as forget.
    public var lastRecord: RunRecord?
    /// The newest record of a backup, whatever its outcome (a failure, a skip): what the menu's "Backup failed at
    /// <time>" and its reason come from, so a step that ran since can't stand in for it. A status from before it
    /// existed decodes it from `lastRecord` when that is a backup's record. Done's progress reads it: a skip or a
    /// failure ends the first backup.
    public var latestBackupRecord: RunRecord?
    /// The newest backup record with a verdict (`RunOutcome.isVerdict`): what `backupFailed` is decided from
    /// (`activeConditions`), so the menu's "Backup failed at <time>" and its reason read it, looking past a skip,
    /// pause or lock since. A status from before it existed decodes it from `latestBackupRecord` (or `lastRecord`)
    /// when that is a verdict.
    public var latestBackupVerdict: RunRecord?
    /// Nil when the plan will not run on its own (stopped, invalid, or no confirmed recovery kit).
    public var nextRunAt: Date?
    /// Sorted by raw value.
    public var alerts: [AlertCondition]
    /// The newest backup that saved the data: outcome success, unchanged or warning (Ruling P2-4), so the
    /// menu can say "Backed up at <time>" whatever has run since. Nil if none is in the recent history.
    public var lastBackup: RunRecord?
    /// `PlanRunHistory.repositorySize`.
    public var repositorySize: RepositorySize?
    public var setupState: PlanSetupState

    /// `setupState` nil derives it from the plan (`PlanSetupState(plan:)`).
    public init(
        plan: Plan, phase: PlanPhase, lastRecord: RunRecord?, nextRunAt: Date?, alerts: [AlertCondition],
        lastBackup: RunRecord? = nil, repositorySize: RepositorySize? = nil, setupState: PlanSetupState? = nil,
        latestBackupRecord: RunRecord? = nil, latestBackupVerdict: RunRecord? = nil
    ) {
        self.plan = plan
        self.phase = phase
        self.lastRecord = lastRecord
        let latest = latestBackupRecord ?? Self.backupRecord(lastRecord)
        self.latestBackupRecord = latest
        self.latestBackupVerdict = latestBackupVerdict ?? Self.verdict(latest)
        self.nextRunAt = nextRunAt
        self.alerts = alerts
        self.lastBackup = lastBackup
        self.repositorySize = repositorySize
        self.setupState = setupState ?? PlanSetupState(plan: plan)
    }

    private enum CodingKeys: String, CodingKey {
        case plan, phase, lastRecord, nextRunAt, alerts, lastBackup, repositorySize, setupState, latestBackupRecord
        case latestBackupVerdict
    }

    private static func backupRecord(_ record: RunRecord?) -> RunRecord? {
        record?.operation == .backup ? record : nil
    }

    private static func verdict(_ record: RunRecord?) -> RunRecord? {
        record?.outcome.isVerdict == true ? record : nil
    }

    /// A status from an agent before schema 3 has no `lastBackup`, `repositorySize` or `setupState`: the
    /// first two decode as nil and the setup state is derived from the plan.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(Plan.self, forKey: .plan)
        phase = try c.decode(PlanPhase.self, forKey: .phase)
        lastRecord = try c.decodeIfPresent(RunRecord.self, forKey: .lastRecord)
        latestBackupRecord = try c.decodeIfPresent(RunRecord.self, forKey: .latestBackupRecord)
            ?? Self.backupRecord(lastRecord)
        latestBackupVerdict = try c.decodeIfPresent(RunRecord.self, forKey: .latestBackupVerdict)
            ?? Self.verdict(latestBackupRecord)
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        alerts = try c.decode([AlertCondition].self, forKey: .alerts)
        lastBackup = try c.decodeIfPresent(RunRecord.self, forKey: .lastBackup)
        repositorySize = try c.decodeIfPresent(RepositorySize.self, forKey: .repositorySize)
        setupState = try c.decodeIfPresent(PlanSetupState.self, forKey: .setupState) ?? PlanSetupState(plan: plan)
    }
}

/// Where a plan is in setup (Ruling P2-3). JSON: the case name as a string.
public enum PlanSetupState: String, Codable, Sendable {
    /// The recovery kit has never been confirmed: "Setup not finished".
    case unfinished
    /// Setup finished, but the kit must be confirmed again (the repository or a secret changed): "New
    /// recovery kit needed".
    case needsNewKit
    /// The current recovery kit is confirmed.
    case complete

    /// Confirmed kit → complete; unconfirmed and never finished setup → unfinished; unconfirmed after
    /// setup → needs a new kit.
    public init(plan: Plan) {
        if plan.recoveryKitConfirmedAt != nil {
            self = .complete
        } else {
            self = plan.setupCompletedAt == nil ? .unfinished : .needsNewKit
        }
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

/// `probeRepositoryCredentials`'s request: typed credentials (the repository password, and any storage keys or
/// environment values typed with it) to try on the plan's repository without saving them. Settings' Storage tab
/// checks them before saving. Its descriptions and mirror never include a value, like `SecretEntry`'s.
public struct CredentialProbeRequest: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public var planID: UUID
    public var secrets: [SecretEntry]

    public init(planID: UUID, secrets: [SecretEntry]) {
        self.planID = planID
        self.secrets = secrets
    }

    public var description: String {
        "CredentialProbeRequest(plan: \(planID.uuidString), secrets: [\(secrets.map(\.key.account).joined(separator: ", "))])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["planID": planID, "secrets": secrets.map(\.key.account)], displayStyle: .struct)
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

/// `backUpNow`'s reply: the status, and whether the one plan asked for was already backing up (a scheduled run,
/// say), which isn't a refusal: the backup the caller wanted is running. Always false for every plan (nil).
/// JSON: `{"alreadyRunning":true,"status":{…}}`. An agent from before this type answered with a bare
/// `AgentStatus`, which decodes as not already running.
public struct BackUpNowReply: Codable, Sendable, Equatable {
    public var status: AgentStatus
    public var alreadyRunning: Bool

    public init(status: AgentStatus, alreadyRunning: Bool) {
        self.status = status
        self.alreadyRunning = alreadyRunning
    }

    private enum CodingKeys: String, CodingKey { case status, alreadyRunning }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.status) else {
            status = try AgentStatus(from: decoder)
            alreadyRunning = false
            return
        }
        status = try c.decode(AgentStatus.self, forKey: .status)
        alreadyRunning = try c.decodeIfPresent(Bool.self, forKey: .alreadyRunning) ?? false
    }
}

/// `probeRepository`'s reply (Ruling P2-2): what is at the plan's repository address.
/// JSON: `{"state":{"type":"empty"}}`, `{"state":{"type":"existing","report":{…}}}` or
/// `{"state":{"type":"passwordRejected"}}`.
public struct RepositoryProbe: Codable, Sendable, Equatable {
    public enum State: Codable, Sendable, Equatable {
        /// Nothing there (`restic cat config` exit 10): a repository can be created.
        case empty
        /// A repository the plan's password opens, with what `adopt` would report.
        case existing(AdoptReport)
        /// A repository is there, and the plan's password doesn't open it (restic's exit 12). Setup's first
        /// probe is made before the user has typed that repository's password, so this is how it learns that
        /// one is there.
        case passwordRejected

        private enum CodingKeys: String, CodingKey { case type, report }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "empty": self = .empty
            case "existing": self = .existing(try c.decode(AdoptReport.self, forKey: .report))
            case "passwordRejected": self = .passwordRejected
            case let other: throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown repository probe state \(other)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .empty: try c.encode("empty", forKey: .type)
            case .existing(let report):
                try c.encode("existing", forKey: .type)
                try c.encode(report, forKey: .report)
            case .passwordRejected: try c.encode("passwordRejected", forKey: .type)
            }
        }
    }

    public var state: State

    public init(state: State) {
        self.state = state
    }
}

/// `recoveryKit`'s reply (Ruling P2-5): the plan and every secret the agent holds for it, for the app to
/// show in the recovery kit. Only the signed app receives it, and holds it only while the kit is open. Its
/// descriptions and mirror never include a value, like `SecretEntry`'s.
public struct RecoveryKitSecrets: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public var plan: Plan
    /// The repository password; for S3, both keys; for a raw repository, each environment value in the
    /// plan's order; then the check-in URL when the plan has one.
    public var secrets: [SecretEntry]

    public init(plan: Plan, secrets: [SecretEntry]) {
        self.plan = plan
        self.secrets = secrets
    }

    public var description: String {
        "RecoveryKitSecrets(plan: \(plan.id.uuidString) \"\(plan.name)\", secrets: [\(secrets.map(\.key.account).joined(separator: ", "))])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["plan": plan, "secrets": secrets.map(\.key.account)], displayStyle: .struct)
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

/// `requestLocationPermission`'s reply: the agent's Location Services authorisation once the user has
/// answered the prompt (or at once, if they answered before).
public struct LocationPermissionReply: Codable, Sendable, Equatable {
    /// True for "authorisedAlways" and "authorisedWhenInUse", which macOS treats alike.
    public var authorised: Bool
    /// "notDetermined", "restricted", "denied", "authorisedAlways", "authorisedWhenInUse" or "unknown".
    public var status: String
    /// False when Location Services is off for the whole Mac: the agent then answers at once, without asking
    /// macOS (which would show no prompt and leave the request waiting). Nil from an agent older than Task 15.
    public var servicesEnabled: Bool?

    public init(authorised: Bool, status: String, servicesEnabled: Bool? = nil) {
        self.authorised = authorised
        self.status = status
        self.servicesEnabled = servicesEnabled
    }
}
