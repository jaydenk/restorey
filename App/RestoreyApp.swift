import AppKit
import OSLog
import RestoreyCore

/// The app is UI only (spec §8): a status item, the windows `WindowRouter` opens, plus a Debug-only developer
/// window. Its engine job is to keep the agent installed, current and alive, and only when this copy is the
/// installed one.
///
/// The entry point drives `NSApplication` directly rather than through SwiftUI's `App`, so `MainMenu` stays the
/// menu and no SwiftUI scene opens or restores a window of its own.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let damagedMessage = "This copy of Restorey is damaged. Reinstall it."

    private var statusItem: StatusItemController?
    private var supervisor: AgentSupervisor?
    private let router = WindowRouter()
    private var mode = ShellMode.running
    #if DEBUG
    private var developerWindow: DeveloperWindowController?
    #endif

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUp()
        guard let statusItem else { return }
        router.state.statusItemHidden = !statusItem.isVisible
        statusItem.observeVisibility { [weak self] visible in self?.router.state.statusItemHidden = !visible }
        // Checked once launch is over, on the next turn of the run loop, so it reads the saved visibility.
        DispatchQueue.main.async { [weak self] in
            guard let self, let statusItem = self.statusItem else { return }
            if let opening = shellOpeningAtLaunch(mode: self.mode, statusItemVisible: statusItem.isVisible) {
                self.open(opening)
            }
        }
    }

    /// Opening the app again from Finder, Spotlight or `open` while it runs: the only way in for someone who
    /// can't see the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open(shellOpeningOnReopen(mode: mode, statusItemVisible: statusItem?.isVisible ?? false))
        return false
    }

    /// Nothing is state-restored (every window sets `isRestorable = false`); answering at all keeps macOS 14+'s
    /// restoration machinery from running undecided.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func open(_ opening: ShellOpening) {
        guard opening == .damagedNotice else { return router.show(opening) }
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = Self.damagedMessage
        alert.runModal()
    }

    private func setUp() {
        let identity: Identity
        do {
            identity = try Identity.fromBundle(.main)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Restorey", category: "app")
                .fault("Can't read the identity from Info.plist: \(String(describing: error), privacy: .public)")
            mode = .broken
            statusItem = StatusItemController(broken: Self.damagedMessage)
            return
        }
        let log = AppLog(identity: identity, kind: .app)

        // The gate: a copy outside /Applications, or translocated, touches nothing of the agent's.
        switch InstallLocation.check() {
        case .refused(let verdict):
            log.info("Not touching the agent: this copy at \(Bundle.main.bundlePath) is \(verdict)")
            mode = .refused
            statusItem = StatusItemController(refused: verdict)
        case .installed(let copy):
            let supervisor = AgentSupervisor(installed: copy, identity: identity, log: log)
            self.supervisor = supervisor
            let statusItem = StatusItemController(supervisor: supervisor, router: router)
            #if DEBUG
            let developer = DeveloperWindowController(supervisor: supervisor, identity: identity)
            developerWindow = developer
            statusItem.setDeveloperAction { developer.show() }
            #endif
            self.statusItem = statusItem
            supervisor.start()
        }
    }

    /// A status item app: closing the developer window doesn't quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
