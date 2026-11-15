import AppKit
import RestoreyCore

/// The earlier-snapshots confirmation (Task 14b): `DestructiveAlert`'s NSAlert, whose Cancel is the default (Return)
/// and whose destructive "Remove N Snapshots" never is. Shown as a sheet on the key window when there is one,
/// otherwise as its own window.
///
/// Escape: NSAlert gives Escape to a button titled "Cancel" (NSAlert.h, `-addButtonWithTitle:`), but Cancel's one key
/// equivalent is Return here (live finding L1), so while the alert is up a local key monitor turns Escape in its
/// window into a click on Cancel.
@MainActor
enum DestructiveConfirmation {
    /// True only when the user chose the destructive button.
    static func ask(_ text: EarlierSnapshotsText.Confirmation) async -> Bool {
        let built = DestructiveAlert.make(text)
        let alertWindow = built.alert.window
        let cancel = built.cancel
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 is Escape; only in the alert's own window, and only without modifiers.
            guard event.keyCode == 53, event.window === alertWindow,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        guard let window = NSApplication.shared.keyWindow, window.attachedSheet == nil else {
            return WindowActivation.runModal(built.alert) == .alertSecondButtonReturn
        }
        return await withCheckedContinuation { continuation in
            built.alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }
}
