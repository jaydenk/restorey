import Foundation

/// What a save does with a plan's check-in URL (Ruling R53). The app can't read a saved URL back, so its
/// field is empty after every load or save: an empty field must mean "unchanged", and removing the URL,
/// the plan's dead-man's switch, takes an explicit control.
public struct CheckInIntent: Sendable, Equatable {
    /// The value for `Plan.hasCheckInURL`. False makes the agent delete any stored URL.
    public var hasCheckInURL: Bool
    /// A new URL to send as a `SecretEntry`, or nil to send none.
    public var secret: String?

    public init(hasCheckInURL: Bool, secret: String?) {
        self.hasCheckInURL = hasCheckInURL
        self.secret = secret
    }
}

public enum CheckInIntentError: Error, Equatable, CustomStringConvertible {
    /// A new URL and "Remove check-in URL" at once.
    case urlAndRemove

    public var description: String {
        switch self {
        case .urlAndRemove: "Either enter a new check-in URL or remove it, not both."
        }
    }
}

/// - Parameters:
///   - existing: the stored plan's `hasCheckInURL` (false for a new plan).
///   - field: the check-in URL field; surrounding whitespace is ignored.
///   - remove: the "Remove check-in URL" control.
public func checkInIntent(existing: Bool, field: String, remove: Bool) throws -> CheckInIntent {
    let url = field.trimmingCharacters(in: .whitespacesAndNewlines)
    if !url.isEmpty {
        guard !remove else { throw CheckInIntentError.urlAndRemove }
        return CheckInIntent(hasCheckInURL: true, secret: url)
    }
    if remove { return CheckInIntent(hasCheckInURL: false, secret: nil) }
    return CheckInIntent(hasCheckInURL: existing, secret: nil)
}
