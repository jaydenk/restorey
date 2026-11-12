import AppKit
import OSLog
import RestoreyCore

/// The app is UI only (spec §8): a status item, plus a Debug-only developer window. Its engine job is to
/// keep the agent installed, current and alive, and only when this copy is the installed one.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var supervisor: AgentSupervisor?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identity: Identity
        do {
            identity = try Identity.fromBundle(.main)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Restorey", category: "app")
                .fault("Can't read the identity from Info.plist: \(String(describing: error), privacy: .public)")
            statusItem = StatusItemController(broken: "This copy of Restorey is damaged. Reinstall it.")
            return
        }
        let log = AppLog(identity: identity, kind: .app)

        // The gate: a copy outside /Applications, or translocated, touches nothing of the agent's.
        switch InstallLocation.check() {
        case .refused(let verdict):
            log.info("Not touching the agent: this copy at \(Bundle.main.bundlePath) is \(verdict)")
            statusItem = StatusItemController(refused: verdict)
        case .installed(let copy):
            let supervisor = AgentSupervisor(installed: copy, identity: identity, log: log)
            self.supervisor = supervisor
            let statusItem = StatusItemController(supervisor: supervisor)
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
