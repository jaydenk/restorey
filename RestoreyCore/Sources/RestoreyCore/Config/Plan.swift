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
    public var createdAt: Date

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
        createdAt: Date
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
        self.createdAt = createdAt
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
            conditions: Conditions(battery: .minimumPercent(20), skipOnConstrainedNetwork: true),
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
        switch schedule {
        case .interval(let seconds):
            if seconds < Self.minimumIntervalSeconds { errors.append(.intervalTooShort(seconds: seconds)) }
        }
        for type in fileTypeExclusions where Self.normalisedFileType(type) == nil {
            errors.append(.invalidFileType(type))
        }
        return errors
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
public enum BatteryRule: Codable, Sendable, Equatable {
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

public struct Conditions: Codable, Sendable, Equatable {
    public var battery: BatteryRule
    public var skipOnConstrainedNetwork: Bool

    public init(battery: BatteryRule = .minimumPercent(20), skipOnConstrainedNetwork: Bool = true) {
        self.battery = battery
        self.skipOnConstrainedNetwork = skipOnConstrainedNetwork
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
