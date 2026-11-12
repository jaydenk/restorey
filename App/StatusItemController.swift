import AppKit
import RestoreyCore

/// The menu bar item. Plan 2 replaces it with the designed menu (spec §5.1); until then it is one line
/// per plan, "Back Up Now" and Quit, and it says plainly when the agent isn't working.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private enum Mode {
        /// This copy may not touch the agent (`InstallVerdict` other than `.ok`).
        case refused(InstallVerdict)
        /// The identity keys are missing from Info.plist: a broken build.
        case broken(String)
        case running(AgentSupervisor)
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let mode: Mode
    #if DEBUG
    private var openDeveloperWindow: (() -> Void)?
    #endif

    init(refused verdict: InstallVerdict) {
        mode = .refused(verdict)
        super.init()
        setUp()
    }

    init(broken message: String) {
        mode = .broken(message)
        super.init()
        setUp()
    }

    init(supervisor: AgentSupervisor) {
        mode = .running(supervisor)
        super.init()
        setUp()
        supervisor.observe { [weak self] in self?.refreshIcon() }
    }

    #if DEBUG
    func setDeveloperAction(_ action: @escaping () -> Void) {
        openDeveloperWindow = action
    }
    #endif

    private func setUp() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
    }

    private var iconState: StatusIconState {
        switch mode {
        case .refused: .warning
        case .broken: .error
        case .running(let supervisor): statusIconState(health: supervisor.health, status: supervisor.status)
        }
    }

    private func refreshIcon() {
        let symbol = switch iconState {
        case .neutral: "externaldrive.badge.timemachine"
        case .warning: "externaldrive.trianglebadge.exclamationmark"
        case .error: "externaldrive.badge.xmark"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Restorey")
        if case .refused = mode { item.button?.toolTip = "Move Restorey to Applications" }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch mode {
        case .refused(let verdict):
            menu.addItem(line("Move Restorey to Applications"))
            menu.addItem(line(verdict == .translocated
                ? "macOS is running this copy from a temporary location."
                : "Restorey only runs from the Applications folder."))
        case .broken(let message):
            menu.addItem(line(message))
        case .running(let supervisor):
            addRunningItems(to: menu, supervisor)
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Restorey", key: "q", #selector(quit)))
    }

    private func addRunningItems(to menu: NSMenu, _ supervisor: AgentSupervisor) {
        let health = supervisor.health
        switch health {
        case .checking:
            menu.addItem(line("Connecting to the background agent…"))
        case .healthy:
            break
        case .updating:
            menu.addItem(line("Finishing the current backup before updating the agent"))
        case .waitingForUpdate:
            menu.addItem(line("Updating the background agent…"))
        case .switchedOff:
            menu.addItem(line("Background agent is switched off"))
            menu.addItem(action("Open Login Items…", #selector(openLoginItems)))
        case .notRunning(let reachable):
            menu.addItem(line(reachable ? "Background agent isn't working properly" : "Background agent isn't running"))
            menu.addItem(action("Restart Agent", #selector(restartAgent)))
            menu.addItem(action("Open Login Items…", #selector(openLoginItems)))
        case .damaged:
            // No action: re-registering can't fix a bundle that's missing the agent's plist.
            menu.addItem(line("Restorey's installation is damaged — reinstall it from the download"))
        case .failed(let message):
            menu.addItem(line(message))
            menu.addItem(action("Restart Agent", #selector(restartAgent)))
        }

        // In any other state the status may be from before a change, so it isn't shown.
        if showsPlanLines(health) {
            if let status = supervisor.status {
                if let configError = status.configError {
                    menu.addItem(line("Restorey can't read its settings: \(configError)"))
                }
                if status.plans.isEmpty { menu.addItem(line("No backup plans yet")) }
                for plan in status.plans {
                    menu.addItem(line("\(plan.plan.name): \(Self.describe(plan.phase))"))
                }
            } else {
                menu.addItem(line("Waiting for the background agent…"))
            }
        }
        menu.addItem(.separator())
        let backUp = action("Back Up Now", #selector(backUpNow))
        backUp.isEnabled = allowsBackUpNow(health) && !(supervisor.status?.plans.isEmpty ?? true)
        menu.addItem(backUp)

        #if DEBUG
        menu.addItem(.separator())
        menu.addItem(action("Developer…", #selector(openDeveloper)))
        #endif
    }

    static func describe(_ phase: PlanPhase) -> String {
        switch phase {
        case .idle:
            return "Idle"
        case .running(_, retrying: .some):
            return "Can't reach the repository, retrying"
        case .running(let progress, retrying: nil):
            guard let progress else { return "Backing up" }
            return "Backing up, \(Int((progress.percentDone * 100).rounded(.down))) %"
        case .paused(let until):
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .stopped(let reason):
            return "Stopped: \(reason)"
        case .skipped(let reason):
            return reason.summary
        }
    }

    private func line(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    private var supervisor: AgentSupervisor? {
        if case .running(let supervisor) = mode { return supervisor }
        return nil
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func restartAgent() {
        supervisor?.restartAgent()
    }

    @objc private func openLoginItems() {
        supervisor?.openLoginItems()
    }

    @objc private func backUpNow() {
        guard let supervisor else { return }
        Task {
            if case .failure(let error) = await supervisor.connection.backUpNow(nil) {
                let alert = NSAlert()
                alert.messageText = "Restorey couldn't start the backup"
                alert.informativeText = error.description
                NSApplication.shared.activate()
                alert.runModal()
            }
        }
    }

    #if DEBUG
    @objc private func openDeveloper() {
        openDeveloperWindow?()
    }
    #endif
}
