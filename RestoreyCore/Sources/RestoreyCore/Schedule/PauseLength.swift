import Foundation

/// How long Pause stops a plan. A fixed set, not a number: the agent enforces it, so a request for any other
/// length is refused rather than stretched (v0.1.1).
public enum PauseLength: String, Codable, Sendable, CaseIterable {
    case oneHour
    case fourHours
    case oneDay

    /// The longest pause: a stored `pausedUntil` is never more than this after now unless the clock went
    /// backwards, which `nextRunDate` and the agent's tick undo (final review M2).
    public static let longest = PauseLength.oneDay

    public var seconds: TimeInterval {
        switch self {
        case .oneHour: 3600
        case .fourHours: 14400
        case .oneDay: 86400
        }
    }

    /// The menu's title for this length.
    public var menuTitle: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .fourHours: "For 4 Hours"
        case .oneDay: "Until Tomorrow"
        }
    }

    /// The length in words, after a verb: "Pause Home for 1 hour" (VoiceOver reads these, since a section header
    /// isn't read with the item under it).
    public var phrase: String {
        switch self {
        case .oneHour: "for 1 hour"
        case .fourHours: "for 4 hours"
        case .oneDay: "until tomorrow"
        }
    }
}
