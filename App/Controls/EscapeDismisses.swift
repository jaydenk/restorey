import SwiftUI

extension View {
    /// Esc closes the sheet, as the Escape key closes any Mac sheet (HIG Sheets; AppKit maps Esc to a sheet's cancel
    /// button). These sheets have only a Done button, and Return is that button's (`.defaultAction`), so Esc gets its
    /// own, invisible one: a button may carry only one shortcut. Esc does what Done does: the sheets that edit apply
    /// their changes straight into the page's unsaved fields, so the page's Revert is the way back, not the sheet's.
    func dismissesOnEscape() -> some View {
        modifier(EscapeDismisses())
    }
}

private struct EscapeDismisses: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                // Only the shortcut is wanted: not seen, clicked, reached by Tab or Full Keyboard Access, or read by
                // VoiceOver. A shortcut doesn't need the button to be hit-testable or focusable.
                .opacity(0)
                .allowsHitTesting(false)
                .focusable(false)
                .accessibilityHidden(true)
        }
    }
}
