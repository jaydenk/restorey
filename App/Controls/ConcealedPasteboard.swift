import AppKit

/// The pasteboard for text the user asked to copy. A secret (a password, a key, a command carrying them) is
/// marked concealed, so clipboard managers that honour the marker (nspasteboard.org) don't keep it; anything
/// else is copied plainly.
@MainActor
enum ConcealedPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ text: String, concealed: Bool = true) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed { pasteboard.setString("", forType: concealedType) }
    }
}
