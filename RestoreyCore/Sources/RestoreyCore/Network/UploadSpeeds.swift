import Foundation

/// The network a measurement belongs to (Measurements in the upload-limit design): a Wi-Fi network by name, Wi-Fi
/// whose name can't be read, wired Ethernet, or anything else (a USB modem, say).
///
/// Wi-Fi names are trimmed and matched as the skip list matches them (`NetworkSettings.matchKey`): ignoring case
/// and Unicode form, not accents.
public enum NetworkKey: Codable, Sendable, Hashable, CodingKeyRepresentable {
    case wiFi(name: String)
    case wiFiUnknown
    case ethernet
    case other

    /// “Kerr Home”, "Wi-Fi (name unknown)", "Ethernet", "this network".
    public var displayName: String {
        switch self {
        case .wiFi(let name): NetworkSettings.trimmed(name)
        case .wiFiUnknown: "Wi-Fi (name unknown)"
        case .ethernet: "Ethernet"
        case .other: "this network"
        }
    }

    public static func == (lhs: NetworkKey, rhs: NetworkKey) -> Bool {
        switch (lhs, rhs) {
        case let (.wiFi(a), .wiFi(b)): matchKey(a) == matchKey(b)
        case (.wiFiUnknown, .wiFiUnknown), (.ethernet, .ethernet), (.other, .other): true
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .wiFi(let name):
            hasher.combine(0)
            hasher.combine(Self.matchKey(name))
        case .wiFiUnknown: hasher.combine(1)
        case .ethernet: hasher.combine(2)
        case .other: hasher.combine(3)
        }
    }

    private static func matchKey(_ name: String) -> String {
        NetworkSettings.matchKey(NetworkSettings.trimmed(name))
    }

    // MARK: Coding

    private static let wiFiPrefix = "wifi:"

    /// `"wifi:<name>"`, `"wifi?"`, `"ethernet"`, `"other"`. The prefix keeps a network named "ethernet" apart
    /// from wired Ethernet.
    var storedForm: String {
        switch self {
        case .wiFi(let name): Self.wiFiPrefix + NetworkSettings.trimmed(name)
        case .wiFiUnknown: "wifi?"
        case .ethernet: "ethernet"
        case .other: "other"
        }
    }

    init?(storedForm: String) {
        switch storedForm {
        case "wifi?": self = .wiFiUnknown
        case "ethernet": self = .ethernet
        case "other": self = .other
        default:
            guard storedForm.hasPrefix(Self.wiFiPrefix) else { return nil }
            self = .wiFi(name: String(storedForm.dropFirst(Self.wiFiPrefix.count)))
        }
    }

    public var codingKey: any CodingKey { StoredKey(stringValue: storedForm) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(storedForm: codingKey.stringValue)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let key = NetworkKey(storedForm: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown network key “\(text)”"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedForm)
    }

    private struct StoredKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// A speed test that didn't give a result: when, and why in a sentence.
public struct SpeedTestFailure: Codable, Sendable, Equatable {
    public var at: Date
    public var reason: String

    public init(at: Date, reason: String) {
        self.at = at
        self.reason = reason
    }
}

/// What the agent keeps for one network: the last successful measurement and the last failure.
public struct UploadSpeedRecord: Codable, Sendable, Equatable {
    public var latest: UploadSpeedMeasurement?
    public var lastFailure: SpeedTestFailure?

    public init(latest: UploadSpeedMeasurement? = nil, lastFailure: SpeedTestFailure? = nil) {
        self.latest = latest
        self.lastFailure = lastFailure
    }
}

/// The payload of `upload-speeds.json`: a measurement, not a setting, so it is a file of its own beside
/// `config.json` and `state.json`.
public struct UploadSpeedsFile: Codable, Sendable, Equatable {
    public var records: [NetworkKey: UploadSpeedRecord]

    public init(records: [NetworkKey: UploadSpeedRecord] = [:]) {
        self.records = records
    }

    public static let schemaVersion = 1
    public static let fileName = "upload-speeds.json"

    public static func store(in directory: URL) -> VersionedStore<UploadSpeedsFile> {
        VersionedStore(
            fileURL: directory.appendingPathComponent(fileName, isDirectory: false),
            currentVersion: schemaVersion, migrations: [:])
    }
}
