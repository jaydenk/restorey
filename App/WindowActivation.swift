import AppKit
import RestoreyCore

/// Brings one of the app's windows to the front as the key window of the active app (O1, fix round 1).
///
/// Why this is needed: since macOS 14, `NSApplication.activate()` is a request the system may refuse ("calling this
/// method doesn't guarantee app activation", AppKit docs; "app activation is driven by user intent", macOS 14
/// AppKit release notes). Restorey is an accessory app that is almost never active when asked for a window. The
/// likely reasons its requests didn't stick (from the docs and the owner's report; not yet confirmed live):
/// - from inside a status-item menu's action, while the menu is still tracking (event-tracking run-loop mode). When
///   tracking ends, the system gives the focus back to the app that was active before the menu opened, so the
///   window just ordered front ends up behind it. So the request is made once tracking is over: in the default
///   run-loop mode, which doesn't run while a menu tracks.
/// - after a Touch ID or password prompt (`OwnerAuthentication`): the prompt is another process's window, and when
///   it goes, macOS returns the focus to whichever app was active before it, which for a request made while
///   Restorey's own activation was still pending is the previous app. So whichever way the prompt ends, the window
///   that asked is brought forward again.
/// The window is ordered front at once either way, so it appears even if activation is refused.
@MainActor
enum WindowActivation {
    static func bringForward(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        let number = window.windowNumber
        // `.default` mode only: never inside a menu's tracking loop.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSApplication.shared.activate()
                NSApplication.shared.window(withWindowNumber: number)?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The open window of `kind`, if there is one.
    static func bringForward(_ kind: AppWindowKind) {
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == kind.rawValue })
        else { return }
        bringForward(window)
    }
}
