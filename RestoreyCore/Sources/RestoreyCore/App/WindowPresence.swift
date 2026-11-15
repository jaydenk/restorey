import Foundation

/// How Restorey shows itself to macOS (`NSApplication.ActivationPolicy`): a menu bar app with no Dock icon or menu
/// bar of its own, or an ordinary app.
public enum AppPolicy: Sendable, Equatable {
    case accessory
    case regular
}

/// Which of Restorey's windows are open, and so how it shows itself (O1, owner ruling 15 Nov 2026): an ordinary app
/// (Dock icon, ⌘-Tab, its own menu bar with Quit) while any window is open, and a menu bar app once the last one
/// closes.
///
/// Why: macOS treats an accessory app as a second-class front app (diagnosis `o1-diagnosis.md`). When a Touch ID
/// prompt goes away, WindowServer hands the front to the next *regular* app and passes over an accessory one, and
/// an accessory app's own request to become active afterwards is refused, so the window that asked fell behind
/// the app the user was in before. An accessory app also has no menu bar, so Restorey's menu (Quit, Edit) never
/// showed while its window was in use.
///
/// "Open" means not closed: a minimised window keeps the Dock icon, which is how it is brought back. Whether
/// Restorey is active when a window closes doesn't matter.
public struct WindowPresence: Sendable {
    public enum Window: Hashable, Sendable {
        case window(AppWindowKind)
        /// The Debug-only Developer window.
        case developer
        /// An alert run on its own (not a sheet), for as long as it is up.
        case alert(UUID)
    }

    public private(set) var open: Set<Window> = []

    public init() {}

    public var policy: AppPolicy { open.isEmpty ? .accessory : .regular }

    /// A window is about to be shown (or brought forward). The new policy when it changes, nil when it doesn't.
    @discardableResult
    public mutating func shown(_ window: Window) -> AppPolicy? {
        let before = policy
        open.insert(window)
        return policy == before ? nil : policy
    }

    /// A window closed. The new policy when it changes, nil when it doesn't.
    @discardableResult
    public mutating func closed(_ window: Window) -> AppPolicy? {
        let before = policy
        open.remove(window)
        return policy == before ? nil : policy
    }

    /// The fallback when macOS refuses the activation (owner ruling): on the next turn of the run loop, a window
    /// still on screen is ordered in front of other apps' windows anyway (`orderFrontRegardless`), though it isn't
    /// key until clicked. A granted activation needs nothing, and a window closed or minimised by then is left alone.
    public static func ordersFrontRegardless(isActive: Bool, windowVisible: Bool) -> Bool {
        !isActive && windowVisible
    }
}
