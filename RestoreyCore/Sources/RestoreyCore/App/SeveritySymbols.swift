import Foundation

/// The shapes that carry a status, so colour is never the only thing that says it (HIG Accessibility: "don't rely
/// on color alone"; HIG Color). The views tint each symbol with a system colour and write the words beside it in
/// the label colour, which keeps the text legible in both appearances and with Increase Contrast.
extension Severity {
    /// A triangle for a warning, an octagon for an error: different outlines, so a person who can't tell orange from
    /// red still can.
    public var symbolName: String {
        switch self {
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// What VoiceOver says for the symbol.
    public var accessibilityLabel: String {
        switch self {
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

extension HistoryRow.Kind {
    /// One shape per outcome in the History list: a tick, a triangle, an octagon and a minus.
    public var symbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: Severity.warning.symbolName
        case .failure: Severity.error.symbolName
        case .skipped: "minus.circle"
        }
    }

    /// What VoiceOver says for the symbol, so the outcome isn't only in the row's words.
    public var accessibilityLabel: String {
        switch self {
        case .success: "Succeeded"
        case .warning: "Finished with a warning"
        case .failure: "Failed"
        case .skipped: "Not run"
        }
    }
}
