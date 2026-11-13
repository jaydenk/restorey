import Foundation

/// Whether a window's passwords and keys show as themselves or as dots (Restore Files and the recovery kit window;
/// owner ruling, 13 Nov 2026). "Show Passwords and Keys" keeps them shown until it is pressed again ("Hide
/// Passwords and Keys"), the window stops being key, or it closes; holding Option shows them only while held.
/// Whether the owner must be confirmed first is the window's business (once per opening); this only says what shows.
public struct SecretReveal: Sendable, Equatable {
    /// Shown by the button, kept until hidden.
    public private(set) var kept = false
    /// Option is held while the window is key.
    public private(set) var peeking = false

    public init() {}

    public var visible: Bool { kept || peeking }

    /// The button's words. Before the owner is confirmed in this opening, pressing it asks, hence the ellipsis.
    public func buttonTitle(authenticated: Bool) -> String {
        if kept { return "Hide Passwords and Keys" }
        return authenticated ? "Show Passwords and Keys" : "Show Passwords and Keys…"
    }

    /// The button was pressed and the owner confirmed (or already had been): keep them shown.
    public mutating func approvedByButton() { kept = true }

    /// The button pressed while shown hides them; pressed while hidden (already confirmed) shows them.
    public mutating func toggle() { kept.toggle() }

    public mutating func optionChanged(_ held: Bool) { peeking = held }

    /// The window is no longer key: nobody is looking at it, so back to dots.
    public mutating func resignedKey() {
        kept = false
        peeking = false
    }

    /// The window closed, or shows another plan.
    public mutating func reset() {
        kept = false
        peeking = false
    }
}
