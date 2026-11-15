import Foundation

// The app shell's decisions (UI design §5–§8): which window a launch or a reopen shows, the windows' kinds and
// titles, and what switching open-at-login on or off does. The app's `WindowRouter`, `AppDelegate` and
// `LoginItem` only carry these out.

/// The Settings window's sections (UI design §6).
public enum SettingsSection: String, CaseIterable, Sendable, Equatable {
    case general
    case plans
    case network
    case history

    public var title: String {
        switch self {
        case .general: "General"
        case .plans: "Plans"
        case .network: "Network"
        case .history: "History"
        }
    }
}

/// The app's windows. There is at most one window of each kind: asking for one that is open brings it to the
/// front (and, for a plan's window, shows that plan in it).
public enum AppWindowKind: String, CaseIterable, Sendable, Hashable {
    case setup
    case settings
    case recoveryKit
    case restoreFiles

    public var title: String {
        switch self {
        case .setup: "Set Up Restorey"
        case .settings: "Restorey Settings"
        case .recoveryKit: "Recovery Kit"
        case .restoreFiles: "Restore Files"
        }
    }
}

/// The note the General section shows while the status item is hidden (UI design §8).
public let statusItemHiddenNote = "Restorey's menu bar icon is hidden. Show it in System Settings → Menu Bar."

/// What this copy of the app is doing, as far as the shell is concerned.
public enum ShellMode: Sendable, Equatable {
    /// The installed copy, supervising the agent.
    case running
    /// A copy outside /Applications or translocated: it only asks to be moved (setup's first step, Task 11).
    case refused
    /// The identity keys are missing from Info.plist; nothing works but the message.
    case broken
}

/// A window the shell opens on its own.
public enum ShellOpening: Sendable, Equatable {
    case setup
    /// Settings, switched to this section, or left on whatever it shows when nil (`settingsRoute`).
    case settings(SettingsSection?)
    /// The damaged-build message, for a broken copy (there is no window to show it in).
    case damagedNotice
}

/// Opening the app again (Finder, Spotlight, `open`) while it runs. A menu bar app has nothing in the Dock, so
/// this is how someone who can't see the status item (hidden, or squeezed out of a full menu bar) still reaches
/// it (UI design §8). An open Settings window comes forward as it is; only while the icon is hidden does it
/// switch to General, which holds the hidden-icon note.
public func shellOpeningOnReopen(mode: ShellMode, statusItemVisible: Bool) -> ShellOpening {
    switch mode {
    case .running: .settings(statusItemVisible ? nil : .general)
    case .refused: .setup
    case .broken: .damagedNotice
    }
}

/// At launch, once the status item has had its saved visibility applied: nothing while the icon shows, since
/// the icon is the way in. A hidden icon leaves no way in, so the window the reopen would show opens at once.
/// (Setup's own launch rule, P2-10, is Task 11's and comes first.)
public func shellOpeningAtLaunch(mode: ShellMode, statusItemVisible: Bool) -> ShellOpening? {
    statusItemVisible ? nil : shellOpeningOnReopen(mode: mode, statusItemVisible: false)
}

// MARK: Settings section and plan

/// What the Settings window shows: a section, and in Plans, a plan.
public struct SettingsRoute: Sendable, Equatable {
    public var section: SettingsSection
    public var planID: UUID?

    public init(section: SettingsSection, planID: UUID? = nil) {
        self.section = section
        self.planID = planID
    }

    /// A new Settings window asked for nothing in particular.
    public static let initial = SettingsRoute(section: .plans)
}

/// What Settings shows after a request for `section` and `planID` (nil when not asked for). `open` is what an
/// open window shows, nil when there is none.
/// - Nothing asked for: an open window keeps what it shows (a reopen brings it forward unchanged); a new one
///   starts at Plans.
/// - A plan asked for: that plan, in `section` or Plans.
/// - Only a section asked for: that section, with no plan selected.
public func settingsRoute(open: SettingsRoute?, section: SettingsSection?, planID: UUID?) -> SettingsRoute {
    if section == nil, planID == nil { return open ?? .initial }
    return SettingsRoute(section: section ?? .plans, planID: planID)
}

/// Where a request to show a plan in Settings → Plans comes from (Task 14c).
public enum PlanRequestSource: Sendable, Equatable {
    /// The user picked the plan in the sidebar.
    case sidebarPick
    /// A route into Settings: the menu's plan line or "Add…" (a plan), or "Settings…" and a reopen (none).
    case route(planID: UUID?)
}

/// Whether the request opens the plan on its first tab, the Overview, when it names no tab of its own: a plan
/// picked or asked for does; a route that asks for no plan keeps the tab shown (review minor 4).
public func planRequestLandsOnFirstTab(_ source: PlanRequestSource) -> Bool {
    switch source {
    case .sidebarPick: true
    case .route(let planID): planID != nil
    }
}

// MARK: Open at login

/// Open at login is on only when `SMAppService.mainApp` is `enabled`. `requiresApproval` means the user
/// switched Restorey off in System Settings → General → Login Items, so it won't open at login.
public func loginItemIsEnabled(_ status: AgentServiceStatus) -> Bool { status == .enabled }

public enum LoginItemChange: Sendable, Equatable {
    case none
    case register
    case unregister
}

/// What switching open at login to `enable` does from `status`. Never a call that can only fail: registering
/// an enabled app or unregistering one that isn't registered (`kSMErrorJobNotFound`). Registering again from
/// `requiresApproval` is allowed: it leaves the user's switch in Login Items as it is.
public func loginItemChange(from status: AgentServiceStatus, enable: Bool) -> LoginItemChange {
    switch (status, enable) {
    case (.enabled, true), (.notRegistered, false), (.notFound, false): .none
    case (.notRegistered, true), (.notFound, true), (.requiresApproval, true): .register
    case (.enabled, false), (.requiresApproval, false): .unregister
    }
}

// MARK: One window per kind

/// The open windows, at most one per key. The router asks for a key's window, makes one only when none is
/// open, and forgets it when it closes, so the next request makes a fresh one (a closed recovery kit's
/// secrets go with its window).
@MainActor
public final class WindowSlots<Key: Hashable, Window: AnyObject> {
    private var windows: [Key: Window] = [:]

    public init() {}

    /// The open window for `key`, or a new one from `make`. `isNew` tells the caller whether to set it up.
    public func window(for key: Key, make: () -> Window) -> (window: Window, isNew: Bool) {
        if let open = windows[key] { return (open, false) }
        let made = make()
        windows[key] = made
        return (made, true)
    }

    public func openWindow(for key: Key) -> Window? { windows[key] }

    /// Forgets `window` if it is the one held for `key`; a stale close of a replaced window is ignored.
    public func closed(_ window: Window, for key: Key) {
        if windows[key] === window { windows[key] = nil }
    }
}
