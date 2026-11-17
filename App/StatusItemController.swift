import AppKit
import RestoreyCore

/// The menu bar item (UI design §5). While the app runs from /Applications its icon and menu are exactly what
/// `MenuPresentation.make` says, built by `MenuBuilder`; the menu updates while it is open, so a backup's progress
/// moves under the pointer. A copy that may not touch the agent, or a broken build, shows a short fixed menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, MenuActionTarget {
    private enum Mode {
        /// This copy may not touch the agent (`InstallVerdict` other than `.ok`).
        case refused(InstallVerdict, WindowRouter)
        /// The identity keys are missing from Info.plist: a broken build.
        case broken(String)
        case running(AgentSupervisor, WindowRouter)
    }

    /// The System Settings panes the banners open. Checked against macOS 27.2: `Privacy_AllFiles` is an anchor of
    /// `com.apple.settings.PrivacySecurity.extension` (its bundle in /System/Library/ExtensionKit/Extensions
    /// lists it), and `com.apple.Notifications-Settings.extension` is the Notifications pane's bundle identifier,
    /// which takes the app to show as `id`. Login Items has its own API (`SMAppService.openSystemSettingsLoginItems`).
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
    static func notificationsURL(bundleID: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
    }

    #if DEBUG
    private static let developer = true
    #else
    private static let developer = false
    #endif

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let mode: Mode
    private var visibilityObservation: NSKeyValueObservation?
    /// Between `menuWillOpen` and `menuDidClose`: changes are drawn into the open menu at once.
    private var menuIsOpen = false
    #if DEBUG
    private var openDeveloperWindow: (() -> Void)?
    #endif

    init(refused verdict: InstallVerdict, router: WindowRouter) {
        mode = .refused(verdict, router)
        super.init()
        setUp()
    }

    init(broken message: String) {
        mode = .broken(message)
        super.init()
        setUp()
    }

    init(supervisor: AgentSupervisor, router: WindowRouter) {
        mode = .running(supervisor, router)
        super.init()
        setUp()
        supervisor.observe { [weak self] in self?.changed() }
    }

    #if DEBUG
    func setDeveloperAction(_ action: @escaping () -> Void) {
        openDeveloperWindow = action
    }
    #endif

    /// False when the user hid the item (System Settings → Menu Bar, or dragged out). True while macOS has
    /// only squeezed it out of a full menu bar: nothing reports that (`NSStatusItem.isVisible`).
    var isVisible: Bool { item.isVisible }

    /// Calls `onChange` with the new visibility whenever it changes (`isVisible` is key-value observable).
    func observeVisibility(_ onChange: @escaping @MainActor (Bool) -> Void) {
        visibilityObservation = item.observe(\.isVisible) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                onChange(self.item.isVisible)
            }
        }
    }

    private func setUp() {
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        if case .refused = mode { item.button?.toolTip = "Move Restorey to Applications" }
        changed()
    }

    // MARK: Content

    /// The icon and menu of a running copy: the one place either is decided.
    private func content(_ supervisor: AgentSupervisor) -> MenuContent {
        MenuPresentation.make(
            health: supervisor.health,
            status: menuStatus(health: supervisor.health, live: supervisor.status, lastKnown: supervisor.lastKnownStatus),
            notificationsAuthorised: supervisor.lastHello?.notificationsAuthorised,
            now: Date(), calendar: .autoupdatingCurrent,
            locale: .autoupdatingCurrent)
    }

    private func changed() {
        switch mode {
        case .refused: setIcon(.warning)
        case .broken: setIcon(.error)
        case .running(let supervisor, _):
            let content = content(supervisor)
            setIcon(content.icon)
            // A closed menu is built when it next opens (`menuNeedsUpdate`).
            if menuIsOpen { MenuBuilder.build(content, into: menu, actions: self, developer: Self.developer) }
        }
    }

    private func setIcon(_ state: StatusIconState) {
        item.button?.image = StatusIcon.image(for: state)
        item.button?.setAccessibilityLabel(StatusIcon.accessibilityDescription(for: state))
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch mode {
        case .refused(let verdict, _):
            menu.removeAllItems()
            let move = NSMenuItem(title: "Move to Applications…", action: #selector(showMoveScreen), keyEquivalent: "")
            move.target = self
            menu.addItem(move)
            menu.addItem(line(verdict == .translocated
                ? "macOS is running this copy from a temporary location."
                : "Restorey only runs from the Applications folder."))
            menu.addItem(.separator())
            menu.addItem(quitItem())
        case .broken(let message):
            menu.removeAllItems()
            menu.addItem(line(message))
            menu.addItem(.separator())
            menu.addItem(quitItem())
        case .running(let supervisor, _):
            // Nothing is highlighted as the menu opens; an item highlighted when it last closed gets its colours back.
            MenuBuilder.willHighlight(nil, in: menu)
            MenuBuilder.build(content(supervisor), into: menu, actions: self, developer: Self.developer)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard case .running = mode else { return }
        MenuBuilder.willHighlight(item, in: menu)
    }

    private func line(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit Restorey", action: #selector(quit), keyEquivalent: "q")
        item.target = self
        return item
    }

    /// Setup's "Move to Applications" screen, for a refused copy.
    @objc private func showMoveScreen() {
        guard case .refused(_, let router) = mode else { return }
        router.showSetup()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Actions

    func menuItemChosen(_ sender: NSMenuItem) {
        guard let command = MenuBuilder.command(of: sender), case .running(let supervisor, let router) = mode else { return }
        perform(command, supervisor, router)
    }

    private func perform(_ command: MenuCommand, _ supervisor: AgentSupervisor, _ router: WindowRouter) {
        let connection = supervisor.connection
        switch command {
        case .banner(let action):
            perform(action, supervisor, router)
        case .openPlan(let planID):
            router.showSettings(section: .plans, planID: planID)
        case .backUpAll:
            AgentActions.backUpNow(nil, connection)
        case .backUp(let planID):
            AgentActions.backUpNow(planID, connection)
        case .pauseAll:
            let plans = choices(supervisor).filter(\.canPause).map(\.id)
            AgentActions.pause(plans, connection)
        case .pause(let planID):
            AgentActions.pause([planID], connection)
        case .resumeAll:
            let plans = choices(supervisor).filter(\.canResume).map(\.id)
            AgentActions.resume(plans, connection)
        case .resume(let planID):
            AgentActions.resume([planID], connection)
        case .restoreFiles(let planID):
            router.showRestoreFiles(planID: planID)
        case .settings:
            router.showSettings()
        case .developer:
            #if DEBUG
            openDeveloperWindow?()
            #endif
        case .quit:
            quit()
        }
    }

    private func perform(_ action: BannerAction, _ supervisor: AgentSupervisor, _ router: WindowRouter) {
        switch action {
        case .openFullDiskAccess:
            // Settings → General holds the tile to drag into the list System Settings opens here.
            router.showSettings(section: .general)
            NSWorkspace.shared.open(Self.fullDiskAccessURL)
        case .restartAgent:
            supervisor.restartAgent()
        case .openLoginItems:
            supervisor.openLoginItems()
        case .turnOnNotifications:
            // The agent posts the notifications, so it is the app to turn them on for.
            if let url = Self.notificationsURL(bundleID: supervisor.identity.agentBundleID) { NSWorkspace.shared.open(url) }
        case .addCheckInURL(let planID):
            router.showSettings(section: .plans, planID: planID, tab: .schedule)
        case .dismissOffMacNote(let planID):
            let connection = supervisor.connection
            AgentActions.run("Restorey couldn’t dismiss the note") { [await connection.dismissOffMacNote(planID)] }
        case .finishSetup, .setUp:
            router.showSetup()
        case .saveRecoveryKit(let planID):
            router.showRecoveryKit(planID: planID)
        case .showDetails(let planID):
            router.showSettings(section: .history, planID: planID)
        }
    }

    /// The plans as the menu showed them, for "All Plans".
    private func choices(_ supervisor: AgentSupervisor) -> [PlanChoice] {
        content(supervisor).actions.plans
    }
}
