import Foundation

/// The unit an upload limit is shown and typed in. The limit itself is stored in KiB/s whatever the unit, so
/// the unit only decides how the number reads back to the person.
public enum UploadLimitUnit: String, Codable, Sendable, CaseIterable {
    case kilobytes = "KB"
    case megabytes = "MB"
}

/// The Mac-wide upload limit (`NetworkSettings.uploadLimit`): none, a fixed rate, or a share of what the
/// network can upload.
/// JSON: `{"kind":"none"}`, `{"kind":"rate","kiB":2048,"unit":"MB"}` or `{"kind":"percent","percent":50}`.
public enum MacUploadLimit: Codable, Sendable, Equatable {
    case none
    /// A fixed rate in KiB/s, remembering the unit the person chose to read it in.
    case rate(kiB: Int, unit: UploadLimitUnit)
    /// A percentage (1 to 100) of the upload speed measured for the network the backup is on.
    case percent(Int)

    private enum CodingKeys: String, CodingKey { case kind, kiB, unit, percent }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none": self = .none
        case "rate": self = .rate(kiB: try c.decode(Int.self, forKey: .kiB), unit: try c.decode(UploadLimitUnit.self, forKey: .unit))
        case "percent": self = .percent(try c.decode(Int.self, forKey: .percent))
        case let other: throw DecodingError.dataCorruptedError(
            forKey: .kind, in: c, debugDescription: "Unknown upload limit kind \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode("none", forKey: .kind)
        case .rate(let kiB, let unit):
            try c.encode("rate", forKey: .kind)
            try c.encode(kiB, forKey: .kiB)
            try c.encode(unit, forKey: .unit)
        case .percent(let percent):
            try c.encode("percent", forKey: .kind)
            try c.encode(percent, forKey: .percent)
        }
    }
}

/// The days a limit window applies on.
public enum LimitDays: String, Codable, Sendable, CaseIterable {
    case everyDay, weekdays, weekends
}

/// When the Mac-wide limit applies: on `days`, from `startMinute` to `endMinute` (minutes after midnight, local
/// time, 0..<1440). A window with the end before the start crosses midnight. Outside it there is no limit.
/// JSON: `{"days":"weekdays","startMinute":480,"endMinute":1080}`.
public struct LimitWindow: Codable, Sendable, Equatable {
    public var days: LimitDays
    public var startMinute: Int
    public var endMinute: Int

    public init(days: LimitDays, startMinute: Int, endMinute: Int) {
        self.days = days
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

extension MacUploadLimit {
    /// The fixed rate in KiB/s, nil for none or a percentage. Temporary bridge for callers that don't yet
    /// read a percentage or a window (Tasks 6 and 8 replace them).
    public var rateKiB: Int? {
        if case .rate(let kiB, _) = self { kiB } else { nil }
    }
}
