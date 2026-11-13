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
    private let setupStore = SetupProgressStore(defaults: .standard)
    /// Set once the launch has decided whether setup opens (P2-10), so it opens at most once by itself.
    private var setupDecidedAtLaunch = false
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
            statusItem = StatusItemController(refused: verdict, router: router)
            let mover = AppMover(bundle: .main, identity: identity, translocated: verdict == .translocated)
            router.makeSetupModel = { [setupStore] in
                // Always the move screen; the saved progress is the installed copy's and is left alone.
                SetupModel(
                    context: .refused(mover),
                    progress: SetupProgress(planID: nil, step: .moveToApplications, addingPlan: false),
                    store: setupStore)
            }
            // A copy outside /Applications can do nothing else, so its one screen opens at once.
            router.showSetup()
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
            let loginItem = LoginItem(installed: copy)
            router.makeSetupModel = { [setupStore] in
                SetupModel(
                    context: .installed(supervisor, loginItem),
                    progress: SetupFlow.opening(
                        saved: setupStore.load(), plans: supervisor.lastKnownStatus?.plans, installed: true),
                    store: setupStore)
            }
            supervisor.observe { [weak self, weak supervisor] in
                guard let self, let supervisor else { return }
                self.openSetupAtLaunchIfNeeded(status: supervisor.status)
            }
            supervisor.start()
        }
    }

    /// P2-10: setup opens at launch while a plan's setup is unfinished or no plan exists, decided on the agent's
    /// first status, since only the agent knows the plans.
    private func openSetupAtLaunchIfNeeded(status: AgentStatus?) {
        guard !setupDecidedAtLaunch, let status else { return }
        setupDecidedAtLaunch = true
        if SetupFlow.resume(saved: setupStore.load(), plans: status.plans, installed: true) != nil {
            router.showSetup()
        }
    }

    /// A status item app: closing the developer window doesn't quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
