import AppKit
import RestoreyCore

/// The earlier-snapshots confirmation (Task 14b): an NSAlert whose default button (Return) is Cancel and whose
/// destructive button, second, reads "Remove N Snapshots". Shown as a sheet on the key window when there is one,
/// otherwise as its own window.
@MainActor
enum DestructiveConfirmation {
    /// True only when the user chose the destructive button.
    static func ask(_ text: EarlierSnapshotsText.Confirmation) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.message
        // The first button is the default (Return), and a button titled Cancel also takes Escape.
        alert.addButton(withTitle: "Cancel")
        let remove = alert.addButton(withTitle: text.button)
        remove.hasDestructiveAction = true
        guard let window = NSApplication.shared.keyWindow, window.attachedSheet == nil else {
            return WindowActivation.runModal(alert) == .alertSecondButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }
}
