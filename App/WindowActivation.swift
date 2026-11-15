import AppKit
import RestoreyCore

/// Brings Restorey's windows to the front and keeps its activation policy in step with them (O1; diagnosis
/// `.superpowers/sdd/2026-11-12-v0.1-ui/o1-diagnosis.md`, owner rulings of 15 Nov 2026).
///
/// - While any of its windows is open, Restorey is an ordinary app (`.regular`: Dock icon, ⌘-Tab, its own menu bar),
///   and a menu bar app (`.accessory`) once the last one closes (`WindowPresence`). As an accessory app it was passed
///   over when a Touch ID prompt went away (WindowServer gives the front to the next regular app), and it had no menu
///   bar for Quit and Edit.
/// - Activation is asked for once, synchronously, while the request that opened the window is being handled (the
///   status-item menu's action, a button). macOS may still refuse it ("calling this method doesn't guarantee app
///   activation", `NSApplication.activate()`); then, on the next turn of the run loop, a window still on screen is
///   ordered in front anyway with `orderFrontRegardless()`, though it isn't key until clicked.
@MainActor
enum WindowActivation {
    private static var presence = WindowPresence()

    /// Shows `window` (one of Restorey's, `id`) in front and asks for the app to be activated.
    static func bringForward(_ window: NSWindow, as id: WindowPresence.Window) {
        windowShown(id)
        window.makeKeyAndOrderFront(nil)
        activate(showing: window)
    }

    /// The open window of `kind`, if there is one.
    static func bringForward(_ kind: AppWindowKind) {
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == kind.rawValue })
        else { return }
        bringForward(window, as: .window(kind))
    }

    /// Runs `alert` as its own window (not a sheet), with Restorey active and an ordinary app while it is up.
    @discardableResult
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let id = WindowPresence.Window.alert(UUID())
        windowShown(id)
        activate(showing: alert.window)
        let response = alert.runModal()
        windowClosed(id)
        return response
    }

    /// One of Restorey's windows is about to show: the Dock icon and menu bar come first, so the activation that
    /// follows is for an ordinary app.
    static func windowShown(_ id: WindowPresence.Window) {
        apply(presence.shown(id))
    }

    /// One of Restorey's windows closed: after the last one, Restorey is a menu bar app again. When it was active,
    /// macOS hands the front back to the app before it.
    static func windowClosed(_ id: WindowPresence.Window) {
        apply(presence.closed(id))
    }

    private static func apply(_ change: AppPolicy?) {
        switch change {
        case .regular?: NSApplication.shared.setActivationPolicy(.regular)
        case .accessory?: NSApplication.shared.setActivationPolicy(.accessory)
        case nil: break
        }
    }

    private static func activate(showing window: NSWindow) {
        NSApplication.shared.activate()
        // A main-actor task runs from the main queue, which runs in every run-loop mode, the modal ones (an alert's,
        // a quit waiting on its question) included, so the fallback comes on the next turn whatever is running.
        Task { @MainActor [weak window] in
            guard let window else { return }
            if WindowPresence.ordersFrontRegardless(isActive: NSApplication.shared.isActive, windowVisible: window.isVisible) {
                window.orderFrontRegardless()
            }
        }
    }
}
