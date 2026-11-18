import AppKit

/// The pasteboard for text the user asked to copy. A secret (a password, a key, a command carrying them) is
/// - marked concealed, so clipboard managers that honour the marker (nspasteboard.org) don't keep it;
/// - kept on this Mac (`.currentHostOnly`), so Universal Clipboard doesn't send it to the user's other devices;
/// - cleared after `secretLifetime`, unless something else has been copied since.
/// Anything else is copied plainly and left alone.
@MainActor
enum ConcealedPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// How long a copied secret stays on the pasteboard.
    static let secretLifetime: Duration = .seconds(90)

    static func copy(_ text: String, concealed: Bool = true) {
        let pasteboard = NSPasteboard.general
        guard concealed else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }
        // Writes after this keep the option (NSPasteboard.h: it persists until the next prepare or clear).
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealedType)
        let written = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: secretLifetime)
            // A later copy (the user's own, or another secret) has its own change count and its own timer.
            if pasteboard.changeCount == written { pasteboard.clearContents() }
        }
    }
}
