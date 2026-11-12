import Foundation
import Testing
@testable import RestoreyCore

struct AppShellTests {
    // MARK: Reopen and launch

    /// Carry list (UI design §8): someone who can't see the status item opens the app again and reaches it.
    @Test func reopenOpensSettingsWhileRunning() {
        #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: true) == .settings(nil))
        #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: false) == .settings(.general))
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
        #expect(statusItemHiddenNote == "Restorey's menu bar icon is hidden. Show it in System Settings → Menu Bar.")
    }

    @Test func eachWindowKindHasItsOwnTitle() {
        let titles = AppWindowKind.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(AppWindowKind.settings.title == "Restorey Settings")
        #expect(SettingsSection.allCases.map(\.title) == ["General", "Plans", "Network", "History"])
    }

    // MARK: Settings route

    private static let planA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let planB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    /// A reopen while Settings is open brings it forward showing what it showed (review fix round 1).
    @Test func reopenKeepsWhatAnOpenSettingsWindowShows() {
        let open = SettingsRoute(section: .plans, planID: Self.planA)
        #expect(settingsRoute(open: open, section: nil, planID: nil) == open)
        let history = SettingsRoute(section: .history)
        #expect(settingsRoute(open: history, section: nil, planID: nil) == history)
    }

    @Test func newSettingsWindowStartsAtPlans() {
        #expect(settingsRoute(open: nil, section: nil, planID: nil) == SettingsRoute(section: .plans, planID: nil))
    }

    @Test func explicitRequestsReplaceWhatIsShown() {
        let open = SettingsRoute(section: .plans, planID: Self.planA)
        #expect(settingsRoute(open: open, section: .general, planID: nil) == SettingsRoute(section: .general))
        #expect(settingsRoute(open: open, section: nil, planID: Self.planB) == SettingsRoute(section: .plans, planID: Self.planB))
        #expect(settingsRoute(open: nil, section: .network, planID: nil) == SettingsRoute(section: .network))
        #expect(settingsRoute(open: nil, section: .plans, planID: Self.planB) == SettingsRoute(section: .plans, planID: Self.planB))
    }

    /// End to end: a visible-icon reopen asks for nothing, so an open window is unchanged.
    @Test func reopenOpeningLeavesTheRouteAlone() throws {
        guard case .settings(let section) = shellOpeningOnReopen(mode: .running, statusItemVisible: true) else {
            Issue.record("expected Settings"); return
        }
        let open = SettingsRoute(section: .history)
        #expect(settingsRoute(open: open, section: section, planID: nil) == open)
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
}
