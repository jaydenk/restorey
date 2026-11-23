import Foundation
import Testing
@testable import RestoreyCore

struct AppShellTests {
    // MARK: Reopen and launch

    /// Carry list (UI design §8): someone who can't see the status item opens the app again and reaches it.
    @Test func reopenOpensTheMainWindowWhileTheIconShows() {
        #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: true) == .main(nil))
    }

    @Test func reopenWithAHiddenIconOpensSettingsGeneral() {
        #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: false) == .settings(.general))
        #expect(shellOpeningAtLaunch(mode: .running, statusItemVisible: false) == .settings(.general))
    }

    /// A copy outside /Applications has no Settings to show; it shows the Move to Applications step.
    @Test func reopenOfARefusedOrBrokenCopy() {
        for visible in [true, false] {
            #expect(shellOpeningOnReopen(mode: .refused, statusItemVisible: visible) == .setup)
            #expect(shellOpeningOnReopen(mode: .broken, statusItemVisible: visible) == .damagedNotice)
        }
    }

    @Test func launchOpensNothingWhileTheIconShows() {
        for mode in [ShellMode.running, .refused, .broken] {
            #expect(shellOpeningAtLaunch(mode: mode, statusItemVisible: true) == nil, "\(mode)")
        }
    }

    /// A hidden icon at launch opens the General section, where the hidden-icon note is.
    @Test func launchWithAHiddenIconOpensTheWayIn() {
        #expect(shellOpeningAtLaunch(mode: .running, statusItemVisible: false) == .settings(.general))
        #expect(shellOpeningAtLaunch(mode: .refused, statusItemVisible: false) == .setup)
        #expect(shellOpeningAtLaunch(mode: .broken, statusItemVisible: false) == .damagedNotice)
    }

    @Test func hiddenNoteWording() {
        #expect(statusItemHiddenNote == "Restorey’s menu bar icon is hidden. Show it in System Settings → Menu Bar.")
    }

    @Test func eachWindowKindHasItsOwnTitle() {
        let titles = AppWindowKind.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(AppWindowKind.main.title == "Restorey")
        #expect(AppWindowKind.settings.title == "Settings")
    }

    @Test func paneOrderTitlesAndSymbols() {
        #expect(MainSection.allCases.map(\.title) == ["Plans", "History"])
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Notifications", "Network"])
        #expect(SettingsPane.allCases.map(\.symbolName) == ["gearshape", "bell.badge", "network"])
        #expect(AppWindowKind.main.isMiniaturizable && !AppWindowKind.settings.isMiniaturizable)
    }

    // MARK: Main window route

    private static let planA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let planB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    /// A reopen while the main window is open brings it forward showing what it showed (review fix round 1).
    @Test func reopenKeepsWhatAnOpenMainWindowShows() {
        let open = MainRoute(section: .plans, planID: Self.planA)
        #expect(mainRoute(open: open, section: nil, planID: nil) == open)
        let history = MainRoute(section: .history)
        #expect(mainRoute(open: history, section: nil, planID: nil) == history)
    }

    @Test func newMainWindowStartsAtPlans() {
        #expect(mainRoute(open: nil, section: nil, planID: nil) == MainRoute(section: .plans, planID: nil))
    }

    @Test func newMainWindowStartsAtTheSectionLastViewed() {
        let remembered = MainRoute(section: .history)
        #expect(mainRoute(open: nil, section: nil, planID: nil, initial: remembered) == remembered)
        // An open window and an explicit request are unaffected.
        let open = MainRoute(section: .plans, planID: Self.planA)
        #expect(mainRoute(open: open, section: nil, planID: nil, initial: remembered) == open)
        #expect(mainRoute(open: nil, section: .plans, planID: nil, initial: remembered) == MainRoute(section: .plans))
    }

    @Test func eachWindowRemembersItsOwnSectionAndIgnoresTheOldKey() throws {
        let name = "RestoreyCoreTests.sections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("network", forKey: "settingsSection")
        #expect(MainSectionPreference(defaults: defaults).load() == .plans)
        #expect(SettingsPanePreference(defaults: defaults).load() == .general)
        SettingsPanePreference(defaults: defaults).save(.notifications)
        #expect(SettingsPanePreference(defaults: defaults).load() == .notifications)
        #expect(MainSectionPreference(defaults: defaults).load() == .plans, "the two keys are separate")
    }

    @Test func theLastSectionIsKeptBetweenLaunches() throws {
        let name = "RestoreyCoreTests.mainSection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = MainSectionPreference(defaults: defaults)
        #expect(preference.load() == .plans, "nothing saved yet: Plans")
        for section in MainSection.allCases {
            preference.save(section)
            #expect(MainSectionPreference(defaults: defaults).load() == section)
        }
        defaults.set("a section removed in a later version", forKey: "mainSection")
        #expect(preference.load() == .plans)
        defaults.set("a pane removed in a later version", forKey: "settingsPane")
        #expect(SettingsPanePreference(defaults: defaults).load() == .general)
    }

    /// The Settings window is titled with the pane, as Apple's Settings windows are, so no pane is called "Settings".
    @Test func thePaneTitlesNeverSaySettings() {
        #expect(!SettingsPane.allCases.map(\.title).contains { $0.contains("Settings") })
    }

    /// Settings has no Minimise button; the main and task windows keep theirs.
    @Test func onlySettingsLacksMinimise() {
        #expect(AppWindowKind.allCases.filter { !$0.isMiniaturizable } == [.settings])
    }

    @Test func explicitRequestsReplaceWhatIsShown() {
        let open = MainRoute(section: .plans, planID: Self.planA)
        #expect(mainRoute(open: open, section: .history, planID: nil) == MainRoute(section: .history))
        #expect(mainRoute(open: open, section: nil, planID: Self.planB) == MainRoute(section: .plans, planID: Self.planB))
        #expect(mainRoute(open: nil, section: .history, planID: nil) == MainRoute(section: .history))
        #expect(mainRoute(open: nil, section: .plans, planID: Self.planB) == MainRoute(section: .plans, planID: Self.planB))
    }

    /// End to end: a visible-icon reopen asks for nothing, so an open window is unchanged.
    @Test func reopenOpeningLeavesTheRouteAlone() throws {
        guard case .main(let section) = shellOpeningOnReopen(mode: .running, statusItemVisible: true) else {
            Issue.record("expected the main window"); return
        }
        let open = MainRoute(section: .history)
        #expect(mainRoute(open: open, section: section, planID: nil) == open)
    }

    // MARK: Open at login

    @Test func loginItemIsOnOnlyWhenEnabled() {
        #expect(loginItemIsEnabled(.enabled))
        for status in [AgentServiceStatus.notRegistered, .requiresApproval, .notFound] {
            #expect(!loginItemIsEnabled(status), "\(status)")
        }
    }

    /// Never a call that can only fail: registering an enabled app or unregistering an unregistered one.
    @Test func loginItemChanges() {
        #expect(loginItemChange(from: .enabled, enable: true) == .none)
        #expect(loginItemChange(from: .enabled, enable: false) == .unregister)
        #expect(loginItemChange(from: .notRegistered, enable: true) == .register)
        #expect(loginItemChange(from: .notRegistered, enable: false) == .none)
        #expect(loginItemChange(from: .notFound, enable: true) == .register)
        #expect(loginItemChange(from: .notFound, enable: false) == .none)
        #expect(loginItemChange(from: .requiresApproval, enable: true) == .register)
        #expect(loginItemChange(from: .requiresApproval, enable: false) == .unregister)
    }

    // MARK: One window per kind

    private final class FakeWindow {}

    @MainActor @Test func secondRequestReusesTheOpenWindow() {
        let slots = WindowSlots<AppWindowKind, FakeWindow>()
        var made = 0
        let first = slots.window(for: .settings) { made += 1; return FakeWindow() }
        let second = slots.window(for: .settings) { made += 1; return FakeWindow() }
        #expect(first.isNew)
        #expect(!second.isNew)
        #expect(first.window === second.window)
        #expect(made == 1)
    }

    @MainActor @Test func eachKindHasItsOwnWindow() {
        let slots = WindowSlots<AppWindowKind, FakeWindow>()
        let windows = AppWindowKind.allCases.map { kind in slots.window(for: kind) { FakeWindow() }.window }
        #expect(Set(windows.map(ObjectIdentifier.init)).count == AppWindowKind.allCases.count)
        for (kind, window) in zip(AppWindowKind.allCases, windows) {
            #expect(slots.openWindow(for: kind) === window)
        }
    }

    /// A closed window is forgotten, so the next request makes a fresh one (the recovery kit's secrets go with
    /// the closed window).
    @MainActor @Test func closedWindowIsReplacedByAFreshOne() {
        let slots = WindowSlots<AppWindowKind, FakeWindow>()
        let first = slots.window(for: .recoveryKit) { FakeWindow() }.window
        slots.closed(first, for: .recoveryKit)
        #expect(slots.openWindow(for: .recoveryKit) == nil)
        let next = slots.window(for: .recoveryKit) { FakeWindow() }
        #expect(next.isNew)
        #expect(next.window !== first)
    }

    /// A late close of a window that was already replaced doesn't drop its replacement.
    @MainActor @Test func staleCloseIsIgnored() {
        let slots = WindowSlots<AppWindowKind, FakeWindow>()
        let first = slots.window(for: .setup) { FakeWindow() }.window
        slots.closed(first, for: .setup)
        let second = slots.window(for: .setup) { FakeWindow() }.window
        slots.closed(first, for: .setup)
        #expect(slots.openWindow(for: .setup) === second)
        slots.closed(second, for: .settings)
        #expect(slots.openWindow(for: .setup) === second)
    }

    // MARK: The tab a plan request lands on (Task 14c, review minor 4)

    @Test func aSidebarPickLandsOnTheFirstTab() {
        #expect(planRequestLandsOnFirstTab(.sidebarPick))
    }

    @Test func theMenuAskingForAPlanLandsOnTheFirstTab() {
        #expect(planRequestLandsOnFirstTab(.route(planID: UUID())))
    }

    /// "Settings…" or a reopen with the window open asks for no plan: the tab shown stays.
    @Test func aRouteForNoPlanKeepsTheTab() {
        #expect(!planRequestLandsOnFirstTab(.route(planID: nil)))
    }

    // MARK: At-launch windows wait for the first activation (review 17e, fix round 2)

    @Test func aUsersLaunchActivatesAndShowsEachLaunchWindowOnce() {
        var gate = LaunchWindowGate()
        // The hidden-icon Settings window is decided before the activation arrives: it waits for it.
        #expect(gate.request(.settings(.general)).isEmpty)
        #expect(gate.becameActive() == [.settings(.general)])
        // Setup, decided on the agent's first status after the activation, opens at once.
        #expect(gate.request(.setup) == [.setup])
        // A later activation (the person coming back to Restorey) opens nothing again, nor does a repeat request.
        #expect(gate.becameActive().isEmpty)
        #expect(gate.request(.setup).isEmpty)
    }

    @Test func aBackgroundLaunchShowsNothingUntilThePersonActivatesTheApp() {
        // `open -g`, or a Shortcuts action run in the background: no activation, so nothing opens.
        var gate = LaunchWindowGate()
        #expect(gate.request(.setup).isEmpty)
        #expect(gate.request(.settings(.general)).isEmpty)
        #expect(gate.request(.setup).isEmpty)
        // The person activates Restorey: each window asked for opens once, in the order asked.
        #expect(gate.becameActive() == [.setup, .settings(.general)])
        #expect(gate.becameActive().isEmpty)
    }
}
