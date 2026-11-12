import Foundation
import Testing
@testable import RestoreyCore

struct AppShellTests {
    // MARK: Reopen and launch

    /// Carry list (UI design §8): someone who can't see the status item opens the app again and reaches it.
    @Test func reopenOpensSettingsWhileRunning() {
        #expect(shellOpeningOnReopen(mode: .running, statusItemVisible: true) == .settings(.plans))
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
