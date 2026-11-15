import AppKit

/// The earlier-snapshots confirmation's NSAlert (Task 14b), built here rather than in the app so its buttons can be
/// tested. The one AppKit type in RestoreyCore.
///
/// NSAlert's own rules (NSAlert.h, `-addButtonWithTitle:`): the first button added gets Return, but any button titled
/// "Cancel" gets Escape instead, so a Cancel added first has no Return and the alert has no default button (live
/// finding L1: AXDefaultButton nil). So Cancel is added first (NSAlert lays it out as the cancel button) and given
/// Return explicitly; `DestructiveConfirmation` (the app) maps Escape to it while the alert is up, since a button has
/// one key equivalent. The destructive button never has Return or Escape.
@MainActor
public enum DestructiveAlert {
    public struct Built {
        public let alert: NSAlert
        public let cancel: NSButton
        public let remove: NSButton
    }

    public static func make(_ text: EarlierSnapshotsText.Confirmation) -> Built {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.message
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        cancel.keyEquivalentModifierMask = []
        let remove = alert.addButton(withTitle: text.button)
        remove.keyEquivalent = ""
        remove.hasDestructiveAction = true
        return Built(alert: alert, cancel: cancel, remove: remove)
    }
}
