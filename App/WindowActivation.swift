import AppKit
import RestoreyCore

/// Brings Restorey's windows to the front and keeps its activation policy in step with them (O1; diagnosis
/// `.superpowers/sdd/2026-11-12-v0.1-ui/o1-diagnosis.md`, owner rulings of 15 Nov 2026). The decisions and their order
/// are `ActivationController`'s (RestoreyCore, tested); this is the AppKit side.
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
    private static let controller = ActivationController(host: AppKitActivationHost())
    /// The About panel while it is up, so its closing is noticed.
    private static var aboutObserver: NSObjectProtocol?

    /// Shows `window` (one of Restorey's, `id`) in front and asks for the app to be activated.
    static func bringForward(_ window: NSWindow, as id: WindowPresence.Window) {
        controller.bringForward(id, window)
    }

    /// Runs `alert` as its own window (not a sheet), with Restorey active and an ordinary app while it is up.
    @discardableResult
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        controller.runModal(alert.window) { alert.runModal() }
    }

    /// One of Restorey's windows closed: after the last one, Restorey is a menu bar app again. When it was active,
    /// macOS hands the front back to the app before it.
    static func windowClosed(_ id: WindowPresence.Window) {
        controller.closed(id)
    }

    /// The app menu's About: the standard panel, counted as a window until it closes (review M2), so closing the last
    /// of Restorey's own windows doesn't leave it on screen in a menu bar app.
    static func showAbout() {
        let before = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
        // The panel AppKit just put on screen: visible now and not before, and none of Restorey's own windows (those
        // have an identifier). Shown again while open, it is already counted.
        guard aboutObserver == nil,
              let panel = NSApplication.shared.windows.first(where: {
                  $0.isVisible && $0.identifier == nil && !before.contains(ObjectIdentifier($0))
              })
        else { return }
        controller.shown(.about)
        aboutObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let observer = aboutObserver { NotificationCenter.default.removeObserver(observer) }
                aboutObserver = nil
                controller.closed(.about)
            }
        }
    }
}

/// `ActivationHost` over `NSApplication` and `NSWindow`.
@MainActor
private final class AppKitActivationHost: ActivationHost {
    var isActive: Bool { NSApplication.shared.isActive }
    var isHidden: Bool { NSApplication.shared.isHidden }

    func setPolicy(_ policy: AppPolicy) {
        switch policy {
        case .regular: NSApplication.shared.setActivationPolicy(.regular)
        case .accessory: NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func unhideWithoutActivation() { NSApplication.shared.unhideWithoutActivation() }
    func orderFront(_ window: NSWindow) { window.makeKeyAndOrderFront(nil) }
    func activate() { NSApplication.shared.activate() }
    func isVisible(_ window: NSWindow) -> Bool { window.isVisible }
    func orderFrontRegardless(_ window: NSWindow) { window.orderFrontRegardless() }

    /// A main-actor task runs from the main queue, which runs in every run-loop mode, the modal ones (an alert's, a
    /// quit waiting on its question) included, so it comes on the next turn whatever is running.
    func nextTurn(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in body() }
    }
}
