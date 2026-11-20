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
    /// `NSCalendarDayChanged`: the tooltip and the menu say "yesterday at 09:05", which is only right on the day they
    /// were made.
    private var dayChangeObserver: NSObjectProtocol?
    /// Between `menuWillOpen` and `menuDidClose`: changes are drawn into the open menu at once.
    private var menuIsOpen = false
    /// Option was held as the menu opened (Option-click), so it shows the diagnostics section until it closes
    /// (audit T1). As in Apple's own menu bar extras, the section comes with the click; it isn't added mid-menu.
    private var showsDiagnostics = false
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
        // Posted when the system's calendar day changes, and on waking after midnight ("If the device is asleep when
        // the day changes, this notification will be posted on wakeup"), so the relative day is made again.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.changed() }
        }
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
            backupStoppedByRepairAt: supervisor.backupStoppedByRepairAt,
            now: Date(), calendar: .autoupdatingCurrent,
            locale: .autoupdatingCurrent)
    }

    private func changed() {
        switch mode {
        case .refused: setIcon(.warning)
        case .broken(let message):
            setIcon(.error)
            item.button?.toolTip = "Restorey — \(message)"
        case .running(let supervisor, _):
            let content = content(supervisor)
            setIcon(content.icon)
            // The state at a glance without opening the menu (audit T9); VoiceOver reads it as the button's help.
            item.button?.toolTip = content.toolTip
            // A closed menu is built when it next opens (`menuNeedsUpdate`).
            if menuIsOpen { build(content, supervisor) }
        }
    }

    private func build(_ content: MenuContent, _ supervisor: AgentSupervisor) {
        MenuBuilder.build(
            content, into: menu, actions: self, developer: Self.developer,
            diagnostics: showsDiagnostics ? diagnostics(supervisor) : nil)
    }

    /// What Option-click shows: this copy's and the agent's versions, and the logs.
    private func diagnostics(_ supervisor: AgentSupervisor) -> MenuDiagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        return MenuDiagnostics(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown",
            health: supervisor.health, agentVersion: supervisor.lastHello?.agentVersion,
            agentBuild: supervisor.lastHello?.agentBuild,
            lastLog: MenuDiagnostics.lastLog(supervisor.status ?? supervisor.lastKnownStatus),
            system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
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
            // Read as the menu is about to open, from the click that opened it.
            showsDiagnostics = NSEvent.modifierFlags.contains(.option)
            build(content(supervisor), supervisor)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
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
        case .pauseAll(let length):
            let plans = choices(supervisor).filter(\.canPause).map(\.id)
            AgentActions.pause(plans, for: length, connection)
        case .pause(let planID, let length):
            AgentActions.pause([planID], for: length, connection)
        case .cancelAll:
            let plans = choices(supervisor).filter(\.canCancel).map(\.id)
            AgentActions.cancel(plans, connection)
        case .cancel(let planID):
            AgentActions.cancel([planID], connection)
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
        case .showLog(let file):
            // Only a file inside the logs folder's runs (`logURL`), and only while it is still there.
            if let url = HistoryPresentation.logURL(file, logsDirectory: supervisor.identity.logsDirectory()),
                FileManager.default.fileExists(atPath: url.path)
            {
                NSWorkspace.shared.open(url)
            } else {
                router.showSettings(section: .history)
            }
        case .showLogsFolder:
            NSWorkspace.shared.activateFileViewerSelecting([supervisor.identity.logsDirectory()])
        case .copyDiagnostics:
            let text = diagnostics(supervisor).text(content(supervisor))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
        case .showSettingsError:
            router.showSettings(section: .plans)
        case .dismissBackupStoppedNote:
            supervisor.dismissBackupStoppedNote()
        }
    }

    /// The plans as the menu showed them, for "All Plans".
    private func choices(_ supervisor: AgentSupervisor) -> [PlanChoice] {
        content(supervisor).actions.plans
    }
}
