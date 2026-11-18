import Foundation

/// The AppKit calls `ActivationController` makes, so the order of them can be tested (O1 fix round 2, review M7).
/// The app's implementation is `WindowActivation` (`NSApplication` and `NSWindow`).
@MainActor
public protocol ActivationHost: AnyObject {
    associatedtype Handle
    var isActive: Bool { get }
    var isHidden: Bool { get }
    func setPolicy(_ policy: AppPolicy)
    /// Shows a hidden app's windows without activating it (`NSApplication.unhideWithoutActivation()`).
    func unhideWithoutActivation()
    /// Orders the window front and makes it key (`makeKeyAndOrderFront`).
    func orderFront(_ window: Handle)
    /// One request to become the active app (`NSApplication.activate()`), which macOS may refuse.
    func activate()
    func isVisible(_ window: Handle) -> Bool
    func orderFrontRegardless(_ window: Handle)
    /// Runs `body` on the next turn of the run loop, in any of its modes.
    func nextTurn(_ body: @escaping @MainActor () -> Void)
}

/// Brings Restorey's windows forward and keeps its activation policy in step with them (O1; diagnosis
/// `o1-diagnosis.md`, owner rulings of 15 Nov 2026), over an `ActivationHost`.
///
/// - The policy changes first (`WindowPresence`), so the activation is asked for by an ordinary app.
/// - A hidden app (⌘H) is shown again without activating it, so the window can be seen whatever macOS decides.
/// - The window is ordered front, then activation is asked for once.
/// - On the next turn, if the activation was refused and the window is still on screen, it is ordered in front of
///   other apps' windows anyway (`orderFrontRegardless`), though it isn't key until clicked.
@MainActor
public final class ActivationController<Host: ActivationHost> {
    private let host: Host
    public private(set) var presence = WindowPresence()

    public init(host: Host) {
        self.host = host
    }

    public func bringForward(_ id: WindowPresence.Window, _ window: Host.Handle) {
        shown(id)
        unhideIfNeeded()
        host.orderFront(window)
        activate(showing: window)
    }

    /// Runs an alert as its own window: an ordinary, active app while it is up, and the policy settled again after.
    public func runModal<Result>(_ window: Host.Handle, _ run: () -> Result) -> Result {
        let id = WindowPresence.Window.alert(UUID())
        shown(id)
        unhideIfNeeded()
        activate(showing: window)
        let result = run()
        closed(id)
        return result
    }

    /// A window Restorey shows itself (the About panel): it counts until `closed`.
    public func shown(_ id: WindowPresence.Window) {
        apply(presence.shown(id))
    }

    public func closed(_ id: WindowPresence.Window) {
        apply(presence.closed(id))
    }

    private func apply(_ change: AppPolicy?) {
        if let change { host.setPolicy(change) }
    }

    private func unhideIfNeeded() {
        if host.isHidden { host.unhideWithoutActivation() }
    }

    private func activate(showing window: Host.Handle) {
        host.activate()
        host.nextTurn { [host] in
            if WindowPresence.ordersFrontRegardless(isActive: host.isActive, windowVisible: host.isVisible(window)) {
                host.orderFrontRegardless(window)
            }
        }
    }
}
