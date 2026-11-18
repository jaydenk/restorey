import RestoreyCore
import SwiftUI

// The type and colour rules for Settings, setup and the sheets, in one place so every pane follows them (HIG Typography,
// Color and Accessibility; Task 17b).
//
// Type: the system text styles at their default weights. A window's or sheet's title is Title 3 in its emphasised
// weight, Semibold (HIG macOS text styles); a section's heading and a status headline are Headline; what a control
// does is explained in Subheadline, never Caption (10 pt is for short tags); an error or a warning is Callout.
//
// Colour: text is in the label colours. What a status means is carried by a tinted symbol with its own shape, never
// by the colour of the words, so the text stays legible and a colour-blind person loses nothing.

extension View {
    /// A window's, sheet's or page's title: Title 3 Semibold, the emphasised weight HIG gives that style.
    func pageTitle() -> some View {
        font(.title3.weight(.semibold))
    }

    /// An explanation under a control: Subheadline in the secondary label colour, wrapping to the width it has.
    func explanatoryNote() -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Severity {
    /// The system colour that tints the severity's symbol: orange for a warning, red for an error. Semantic colours
    /// adapt to the appearance and to Increase Contrast.
    var tint: Color {
        switch self {
        case .warning: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        }
    }
}

extension HistoryRow.Kind {
    /// The symbol's tint: green for a success, orange, red, and the secondary label colour for a run that didn't run.
    var tint: Color {
        switch self {
        case .success: Color(nsColor: .systemGreen)
        case .warning: Severity.warning.tint
        case .failure: Severity.error.tint
        case .skipped: Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// A tinted symbol for a severity, named for VoiceOver.
struct SeverityIcon: View {
    let severity: Severity

    var body: some View {
        Image(systemName: severity.symbolName)
            .foregroundStyle(severity.tint)
            .accessibilityLabel(severity.accessibilityLabel)
    }
}

/// A problem or a warning in a sentence: the severity's symbol, then the words in the label colour, at Callout unless
/// the message is the screen's main text.
struct SeverityText: View {
    let text: String
    var severity: Severity = .error
    var font: Font = .callout

    init(_ text: String, severity: Severity = .error, font: Font = .callout) {
        self.text = text
        self.severity = severity
        self.font = font
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            SeverityIcon(severity: severity)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
    }
}
