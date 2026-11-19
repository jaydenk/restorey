import Foundation

/// A backup plan: what to back up, where to, when, and how long to keep it. Persisted in
/// `config.json` through `VersionedStore`. Secrets never live here (global constraints): the S3
/// keys, repository password, raw environment values and check-in URL are all in the keychain.
public struct Plan: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var repository: Repository
    public var origin: RepositoryOrigin
    /// Passed as `--host` to `backup`, `forget` and `snapshots`.
    public var hostLabel: String
    /// Absolute paths.
    public var sources: [String]
    /// restic exclude patterns (folders, mostly), passed as `--exclude`. They belong to the person: a
    /// migration never rewrites them.
    public var exclusions: [String]
    /// File extensions without the dot, in lower case (`dmg`, `vmdk`), passed as `--iexclude=*.<ext>`
    /// (Ruling R64b). Editable per plan; new plans start with `DefaultExclusions.fileTypes`.
    public var fileTypeExclusions: [String]
    /// Passes `--one-file-system`: other filesystems mounted under a source (an NFS view, a connected
    /// iPhone's DeviceFS) are skipped, while every source's own filesystem, such as a USB drive listed as
    /// a source, is still backed up (Ruling R64c).
    public var oneFileSystem: Bool
    /// Skips items apps mark as not for backup (Time Machine's per-item attribute; `MarkedNotForBackup`, Task 15c).
    /// True for new plans, and for a plan saved before the field existed.
    public var skipsItemsMarkedNotForBackup: Bool
    /// Absolute paths the person chose to back up although they are marked not for backup; an entry also covers
    /// everything under it. Kept when the switch is off, so turning it back on restores the choices.
    public var backUpAnyway: [String]
    public var schedule: Schedule
    public var conditions: Conditions
    public var retention: Retention
    public var pruneEnabled: Bool
    public var forgetCadence: ForgetCadence
    public var uploadLimitKiB: Int?
    public var packSizeMiB: Int?
    public var noSuccessAlertDays: Int
    /// Whether a check-in URL exists in the keychain. The URL itself is a secret and is not stored here.
    public var hasCheckInURL: Bool
    public var recoveryKitConfirmedAt: Date?
    /// When the plan's recovery kit was first confirmed, which finishes setup (Ruling P2-3). Set by the
    /// agent's first `confirmRecoveryKit` and never cleared, so a plan whose kit needs confirming again
    /// (`recoveryKitConfirmedAt` nil) can be told apart from one whose setup was never finished.
    public var setupCompletedAt: Date?
    /// Whether the user has dismissed the "No off-Mac monitoring" note for this plan.
    public var offMacNoteDismissed: Bool
    public var createdAt: Date
    /// When setup adopted the plan's repository ("Use This Repository"). It bounds "snapshots from before
    /// adoption" (product spec §5.6, Task 14b): only snapshots this Mac made by then are offered. Nil for a created
    /// repository, and for a plan adopted before the field existed (`EarlierSnapshots` then bounds by the plan's
    /// earliest own snapshot).
    public var adoptedAt: Date?

    public init(
        id: UUID,
        name: String,
        repository: Repository,
        origin: RepositoryOrigin,
        hostLabel: String,
        sources: [String],
        exclusions: [String],
        fileTypeExclusions: [String],
        oneFileSystem: Bool,
        skipsItemsMarkedNotForBackup: Bool = true,
        backUpAnyway: [String] = [],
        schedule: Schedule,
        conditions: Conditions,
        retention: Retention,
        pruneEnabled: Bool,
        forgetCadence: ForgetCadence,
        uploadLimitKiB: Int?,
        packSizeMiB: Int?,
        noSuccessAlertDays: Int,
        hasCheckInURL: Bool,
        recoveryKitConfirmedAt: Date?,
        setupCompletedAt: Date? = nil,
        offMacNoteDismissed: Bool = false,
        createdAt: Date,
        adoptedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.repository = repository
        self.origin = origin
        self.hostLabel = hostLabel
        self.sources = sources
        self.exclusions = exclusions
        self.fileTypeExclusions = fileTypeExclusions
        self.oneFileSystem = oneFileSystem
        self.skipsItemsMarkedNotForBackup = skipsItemsMarkedNotForBackup
        self.backUpAnyway = backUpAnyway
        self.schedule = schedule
        self.conditions = conditions
        self.retention = retention
        self.pruneEnabled = pruneEnabled
        self.forgetCadence = forgetCadence
        self.uploadLimitKiB = uploadLimitKiB
        self.packSizeMiB = packSizeMiB
        self.noSuccessAlertDays = noSuccessAlertDays
        self.hasCheckInURL = hasCheckInURL
        self.recoveryKitConfirmedAt = recoveryKitConfirmedAt
        self.setupCompletedAt = setupCompletedAt
        self.offMacNoteDismissed = offMacNoteDismissed
        self.createdAt = createdAt
        self.adoptedAt = adoptedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, repository, origin, hostLabel, sources, exclusions, fileTypeExclusions, oneFileSystem
        case skipsItemsMarkedNotForBackup, backUpAnyway
        case schedule, conditions, retention, pruneEnabled, forgetCadence, uploadLimitKiB, packSizeMiB
        case noSuccessAlertDays, hasCheckInURL, recoveryKitConfirmedAt, setupCompletedAt, offMacNoteDismissed
        case createdAt, adoptedAt
    }

    /// `config.json` always has `offMacNoteDismissed` (schema 3), but a plan in a status or save request from
    /// a build before it doesn't: it decodes as false.
    ///
    /// Hand-written: a new field must be added to the properties, `CodingKeys` and this decoder (encoding is
    /// synthesised from `CodingKeys`), and `PlanCodingTests.roundTripsThroughJSON` should set it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repository = try c.decode(Repository.self, forKey: .repository)
        origin = try c.decode(RepositoryOrigin.self, forKey: .origin)
        hostLabel = try c.decode(String.self, forKey: .hostLabel)
        sources = try c.decode([String].self, forKey: .sources)
        exclusions = try c.decode([String].self, forKey: .exclusions)
        fileTypeExclusions = try c.decode([String].self, forKey: .fileTypeExclusions)
        oneFileSystem = try c.decode(Bool.self, forKey: .oneFileSystem)
        // Added after schema 3 with no migration (additive, like `adoptedAt`): absent means the defaults.
        skipsItemsMarkedNotForBackup = try c.decodeIfPresent(Bool.self, forKey: .skipsItemsMarkedNotForBackup) ?? true
        backUpAnyway = try c.decodeIfPresent([String].self, forKey: .backUpAnyway) ?? []
        schedule = try c.decode(Schedule.self, forKey: .schedule)
        conditions = try c.decode(Conditions.self, forKey: .conditions)
        retention = try c.decode(Retention.self, forKey: .retention)
        pruneEnabled = try c.decode(Bool.self, forKey: .pruneEnabled)
        forgetCadence = try c.decode(ForgetCadence.self, forKey: .forgetCadence)
        uploadLimitKiB = try c.decodeIfPresent(Int.self, forKey: .uploadLimitKiB)
        packSizeMiB = try c.decodeIfPresent(Int.self, forKey: .packSizeMiB)
        noSuccessAlertDays = try c.decode(Int.self, forKey: .noSuccessAlertDays)
        hasCheckInURL = try c.decode(Bool.self, forKey: .hasCheckInURL)
        recoveryKitConfirmedAt = try c.decodeIfPresent(Date.self, forKey: .recoveryKitConfirmedAt)
        setupCompletedAt = try c.decodeIfPresent(Date.self, forKey: .setupCompletedAt)
        offMacNoteDismissed = try c.decodeIfPresent(Bool.self, forKey: .offMacNoteDismissed) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        adoptedAt = try c.decodeIfPresent(Date.self, forKey: .adoptedAt)
    }

    /// A new plan with every spec default applied. Callers pass the folder exclusion list
    /// (`DefaultExclusions.paths(home:identity:)`), which depends on the home folder and the build's
    /// identity; the file types default to `DefaultExclusions.fileTypes`.
    public static func newHotPlan(
        name: String,
        repository: Repository,
        origin: RepositoryOrigin,
        hostLabel: String,
        sources: [String],
        exclusions: [String],
        fileTypeExclusions: [String] = DefaultExclusions.fileTypes,
        now: Date
    ) -> Plan {
        let created = origin == .created
        return Plan(
            id: UUID(),
            name: name,
            repository: repository,
            origin: origin,
            hostLabel: hostLabel,
            sources: sources,
            exclusions: exclusions,
            fileTypeExclusions: fileTypeExclusions,
            oneFileSystem: true,
            schedule: .interval(seconds: 3600),
            conditions: Conditions(battery: .minimumPercent(20)),
            retention: Retention(),
            // An adopted repository is someone else's: never prune it, and forget daily rather
            // than after every backup.
            pruneEnabled: created,
            forgetCadence: created ? .afterEachBackup : .daily,
            uploadLimitKiB: nil,
            packSizeMiB: created && repository.isS3 ? 64 : nil,
            noSuccessAlertDays: 3,
            hasCheckInURL: false,
            recoveryKitConfirmedAt: nil,
            createdAt: now
        )
    }
}

public enum PlanValidationError: Error, Equatable, Sendable {
    case emptyHostLabel
    case noSources
    /// A source that does not start with `/`.
    case relativeSource(String)
    /// A schedule interval under `Plan.minimumIntervalSeconds` (includes zero and negative values),
    /// which would leave the plan perpetually due.
    case intervalTooShort(seconds: Int)
    /// A file-type exclusion that isn't a bare extension once trimmed and lower-cased: empty, with a
    /// leading dot, a `/`, a glob character (`*?[]\`) or whitespace inside.
    case invalidFileType(String)
    /// A per-plan upload limit of 0 or less. None is nil, not 0 (the Mac-wide limit has the same rule).
    case uploadLimitNotPositive(kiB: Int)
    /// A source that is the plan's own local repository or lies inside it: backing it up would back up the backups.
    case sourceInsideRepository(String)
}

extension Plan {
    /// Problems that make a plan unsafe to run. The agent and the plan runner refuse an invalid
    /// plan before building restic invocations.
    public static let minimumIntervalSeconds = 300

    public func validationErrors() -> [PlanValidationError] {
        var errors: [PlanValidationError] = []
        if hostLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.emptyHostLabel) }
        if sources.isEmpty { errors.append(.noSources) }
        for source in sources where !source.hasPrefix("/") { errors.append(.relativeSource(source)) }
        if let repositoryPath = repository.localFolderPath {
            for source in sources where SourcePaths.contains(repositoryPath, source) {
                errors.append(.sourceInsideRepository(source))
            }
        }
        switch schedule {
        case .interval(let seconds):
            if seconds < Self.minimumIntervalSeconds { errors.append(.intervalTooShort(seconds: seconds)) }
        }
        for type in fileTypeExclusions where Self.normalisedFileType(type) == nil {
            errors.append(.invalidFileType(type))
        }
        if let uploadLimitKiB, uploadLimitKiB <= 0 { errors.append(.uploadLimitNotPositive(kiB: uploadLimitKiB)) }
        return errors
    }

    /// `fileTypeExclusions` normalised as `config.json` stores them: each entry trimmed and lower-cased,
    /// duplicates dropped (the first kept, in order), invalid entries left as they are for validation to
    /// report. The agent applies this when a plan is saved.
    public mutating func normaliseFileTypeExclusions() {
        var seen: Set<String> = []
        fileTypeExclusions = fileTypeExclusions.compactMap { entry in
            let normalised = Self.normalisedFileType(entry) ?? entry
            return seen.insert(normalised).inserted ? normalised : nil
        }
    }

    /// A file-type exclusion normalised (trimmed, lower case), or nil when what is left isn't a bare
    /// extension: empty, a leading dot, a `/`, a glob character or whitespace inside. The pattern restic
    /// gets is built from this form; matching is case-insensitive anyway.
    public static func normalisedFileType(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."),
            !trimmed.contains(where: { "/*?[]\\".contains($0) || $0.isWhitespace })
        else { return nil }
        return trimmed
    }
}

public enum RepositoryOrigin: String, Codable, Sendable, Equatable {
    /// Restorey ran `restic init`.
    case created
    /// The repository already existed.
    case adopted
}

/// `{"type":"interval","seconds":3600}`
public enum Schedule: Codable, Sendable, Equatable {
    case interval(seconds: Int)

    private enum CodingKeys: String, CodingKey { case type, seconds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "interval": self = .interval(seconds: try c.decode(Int.self, forKey: .seconds))
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown schedule type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try c.encode("interval", forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        }
    }
}

/// `{"type":"minimumPercent","percent":20}` or `{"type":"neverOnBattery"}`
public enum BatteryRule: Codable, Sendable, Hashable {
    case minimumPercent(Int)
    case neverOnBattery

    private enum CodingKeys: String, CodingKey { case type, percent }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "minimumPercent": self = .minimumPercent(try c.decode(Int.self, forKey: .percent))
        case "neverOnBattery": self = .neverOnBattery
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown battery rule type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .minimumPercent(let percent):
            try c.encode("minimumPercent", forKey: .type)
            try c.encode(percent, forKey: .percent)
        case .neverOnBattery:
            try c.encode("neverOnBattery", forKey: .type)
        }
    }
}

/// The plan's own pre-run conditions. The network rules are Mac-wide (`NetworkSettings`) since schema 3.
public struct Conditions: Codable, Sendable, Equatable {
    public var battery: BatteryRule

    public init(battery: BatteryRule = .minimumPercent(20)) {
        self.battery = battery
    }
}

public enum ForgetCadence: String, Codable, Sendable, Equatable {
    case afterEachBackup
    case daily
}

public struct Retention: Codable, Sendable, Equatable {
    public var hourly: Int
    public var daily: Int
    public var weekly: Int
    public var monthly: Int

    public init(hourly: Int = 24, daily: Int = 30, weekly: Int = 52, monthly: Int = 120) {
        self.hourly = hourly
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
    }
}

/// `{"type":"s3","location":{...}}` or `{"type":"raw","repository":...,"environmentNames":[...]}`
public enum Repository: Codable, Sendable, Equatable {
    case s3(S3Location)
    /// A restic repository string restic understands directly, with the names (not values) of the
    /// environment variables it needs. The values are in the keychain.
    case raw(repository: String, environmentNames: [String])

    private enum CodingKeys: String, CodingKey { case type, location, repository, environmentNames }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "s3":
            self = .s3(try c.decode(S3Location.self, forKey: .location))
        case "raw":
            self = .raw(
                repository: try c.decode(String.self, forKey: .repository),
                environmentNames: try c.decode([String].self, forKey: .environmentNames)
            )
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .type, in: c, debugDescription: "Unknown repository type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .s3(let location):
            try c.encode("s3", forKey: .type)
            try c.encode(location, forKey: .location)
        case .raw(let repository, let environmentNames):
            try c.encode("raw", forKey: .type)
            try c.encode(repository, forKey: .repository)
            try c.encode(environmentNames, forKey: .environmentNames)
        }
    }

    /// The value for `RESTIC_REPOSITORY`.
    public var resticRepository: String {
        switch self {
        case .s3(let location): location.resticRepository
        case .raw(let repository, _): repository
        }
    }

    var isS3: Bool {
        if case .s3 = self { return true }
        return false
    }

    /// The folder a local repository is in, standardised, read the way restic reads a location (see `needsNetwork`):
    /// `local:/x` and a plain absolute path `/x` give `/x`. Nil for a storage service, another machine, and a
    /// relative path (`../x`, `local:x`), which can't be placed reliably from the agent's working folder.
    public var localFolderPath: String? {
        guard case .raw(let repository, _) = self else { return nil }
        let path: Substring
        if repository.hasPrefix("/") {
            path = repository[...]
        } else if repository.hasPrefix("local:") {
            path = repository.dropFirst("local:".count)
        } else {
            return nil
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: String(path)).standardizedFileURL.path
    }

    /// Whether restic needs the network to reach this repository (Ruling R69). An S3 or B2 location
    /// always does. A raw location is read the way restic 0.19.1 reads one
    /// (`internal/backend/location/location.go` `Parse`, with the backends `internal/backend/all` registers):
    /// the text before the first `:` names the backend. `local:` is a local folder, and so is a location
    /// with no backend prefix that restic takes as a path (no `:` at all, or starting with `/` or `../`).
    /// Every other backend (`s3:`, `b2:`, `rest:`, `sftp:`, `rclone:`, `azure:`, `gs:`, `swift:`) reaches
    /// another machine. Anything else is a location restic would refuse; it counts as needing the network,
    /// which keeps the conditions as they were for it.
    public var needsNetwork: Bool {
        switch self {
        case .s3: return true
        case .raw(let repository, _): return Self.rawLocationNeedsNetwork(repository)
        }
    }

    static func rawLocationNeedsNetwork(_ location: String) -> Bool {
        guard let colon = location.firstIndex(of: ":") else { return false }
        let scheme = location[..<colon]
        if scheme == "local" { return false }
        if Self.networkSchemes.contains(String(scheme)) { return true }
        // No registered backend: restic treats a path as a local folder.
        return !(location.hasPrefix("/") || location.hasPrefix("../"))
    }

    /// restic 0.19.1's registered backends other than `local`.
    static let networkSchemes: Set<String> = ["azure", "b2", "gs", "rclone", "rest", "s3", "sftp", "swift"]

    /// Where the repository is, for the symbol beside its plan in Settings → Plans: a storage service's (S3, B2,
    /// Azure, Google Cloud Storage, Swift, or rclone's, whose remotes are such services), another machine on the network
    /// (an SFTP or rest-server host, or a backend restic wouldn't know), or this Mac (a folder or drive).
    public var place: RepositoryPlace {
        switch self {
        case .s3: return .cloud
        case .raw(let repository, _):
            guard Self.rawLocationNeedsNetwork(repository) else { return .thisMac }
            let scheme = repository.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return Self.cloudSchemes.contains(scheme) ? .cloud : .server
        }
    }

    /// The backends that are storage services rather than a machine of the user's own.
    static let cloudSchemes: Set<String> = ["azure", "b2", "gs", "rclone", "s3", "swift"]
}

/// Where a plan's repository is (`Repository.place`).
public enum RepositoryPlace: Sendable, Equatable {
    case thisMac
    case cloud
    case server
}

public struct S3Location: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable, Equatable {
        case b2
        case s3
    }

    public var provider: Provider
    public var endpoint: URL
    public var bucket: String
    public var prefix: String

    public init(provider: Provider, endpoint: URL, bucket: String, prefix: String) {
        self.provider = provider
        self.endpoint = endpoint
        self.bucket = bucket
        self.prefix = prefix
    }

    /// `s3:<endpoint>/<bucket>/<prefix>`, with no trailing slash.
    public var resticRepository: String {
        let parts = [endpoint.absoluteString, bucket, prefix].map { $0.trimmingSlashes() }
        return "s3:" + parts.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

private extension String {
    func trimmingSlashes() -> String {
        var s = Substring(self)
        while s.first == "/" { s = s.dropFirst() }
        while s.last == "/" { s = s.dropLast() }
        return String(s)
    }
}
