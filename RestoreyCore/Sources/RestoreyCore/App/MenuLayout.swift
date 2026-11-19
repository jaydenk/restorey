import Foundation

/// What a menu item does when chosen.
public enum MenuCommand: Sendable, Equatable {
    /// A banner's fix, its dismiss, or a plan's "Show Details…".
    case banner(BannerAction)
    /// A plan's status item: open Settings at that plan.
    case openPlan(UUID)
    case backUpAll
    case backUp(UUID)
    /// Pause every plan that can be, for this long.
    case pauseAll(PauseLength)
    case pause(UUID, PauseLength)
    /// Cancel Backup: every running backup, this run only.
    case cancelAll
    case cancel(UUID)
    case resumeAll
    case resume(UUID)
    case restoreFiles(UUID)
    case settings
    /// The Debug-only developer window.
    case developer
    /// Diagnostics (Option-click): open the newest run's log, relative to the logs folder (`HistoryPresentation.logURL`).
    case showLog(String)
    /// Diagnostics: the logs folder in Finder.
    case showLogsFolder
    /// Diagnostics: `MenuDiagnostics.text` on the pasteboard.
    case copyDiagnostics
    case quit
}

/// The SF Symbol beside an item (Task 17d). HIG Menus: "provide icons for all menu items in a group, or none of
/// them", so every item in a plan's section and every banner has one, and the action items below have none.
public enum MenuSymbol: Sendable, Hashable {
    case backedUp
    case noBackup
    case backingUp
    case paused
    case warning
    case error
    case showDetails
    case dismiss

    public var symbolName: String {
        switch self {
        case .backedUp: "checkmark.circle"
        case .noBackup: "circle.dashed"
        case .backingUp: "arrow.up.circle"
        case .paused: "pause.circle"
        case .warning: Severity.warning.symbolName
        case .error: Severity.error.symbolName
        case .showDetails: "clock.arrow.circlepath"
        case .dismiss: "eye.slash"
        }
    }

    /// The severity it shows, drawn in its own colours; nil for a symbol drawn in the menu's text colour (a template
    /// image, which AppKit draws in the highlighted text colour too).
    public var severity: Severity? {
        switch self {
        case .warning: .warning
        case .error: .error
        default: nil
        }
    }
}

/// One ordinary item: a title, an optional subtitle under it (`NSMenuItem.subtitle`), a symbol, a tooltip, and what
/// choosing it does. A disabled item with no command is a plain line.
public struct MenuItem: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var symbol: MenuSymbol?
    public var toolTip: String?
    public var command: MenuCommand?
    public var enabled: Bool
    /// "," for Settings…, "q" for Quit, otherwise none.
    public var keyEquivalent: String
    /// What VoiceOver reads for the item. Nil: its title (AppKit's default).
    public var accessibilityLabel: String?

    public init(
        _ title: String, subtitle: String? = nil, symbol: MenuSymbol? = nil, toolTip: String? = nil,
        command: MenuCommand? = nil, enabled: Bool = true, keyEquivalent: String = "", accessibilityLabel: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.toolTip = toolTip
        self.command = command
        self.enabled = enabled
        self.keyEquivalent = keyEquivalent
        self.accessibilityLabel = accessibilityLabel
    }

    /// A line that says something and does nothing.
    public static func line(_ title: String, toolTip: String? = nil) -> MenuItem {
        MenuItem(title, toolTip: toolTip, enabled: false)
    }
}

/// One row of the status item's menu, in order. The app turns each into an `NSMenuItem`; everything about which
/// rows there are, what they say and what they do is decided here.
public enum MenuRow: Sendable, Equatable {
    /// A section header (`NSMenuItem.sectionHeader(title:)`): a plan's name, or "Diagnostics".
    case header(String)
    case item(MenuItem)
    /// The progress bar under a running plan's status. `name` is for VoiceOver. No fraction: restic is still counting
    /// the files, so the bar has no end (Task 16e).
    case progress(planID: UUID, name: String, fraction: Double?)
    /// A submenu, always enabled so its items can be seen (HIG Menus); `items` say whether each can be chosen.
    case submenu(title: String, items: [MenuRow])
    case separator
}

/// What Option-click adds to the menu (audit T1): versions, the agent's state, and the logs. Nothing in it changes a
/// backup or a setting.
public struct MenuDiagnostics: Sendable, Equatable {
    public var appVersion: String
    public var appBuild: String
    public var health: AgentHealthState
    /// From the agent's last `hello`; nil before it has answered.
    public var agentVersion: String?
    public var agentBuild: String?
    /// The newest run's log, relative to the logs folder; nil when no run has one.
    public var lastLog: String?
    /// "macOS 27.2 (27C60)" or similar, for the copied text.
    public var system: String

    public init(
        appVersion: String, appBuild: String, health: AgentHealthState, agentVersion: String?, agentBuild: String?,
        lastLog: String?, system: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.health = health
        self.agentVersion = agentVersion
        self.agentBuild = agentBuild
        self.lastLog = lastLog
        self.system = system
    }

    /// The newest run record with a log among the plans the status lists.
    public static func lastLog(_ status: AgentStatus?) -> String? {
        status?.plans.compactMap(\.lastRecord).filter { !$0.logFile.isEmpty }.max { $0.endedAt < $1.endedAt }?.logFile
    }

    public var appLine: String { "Restorey \(appVersion) (\(appBuild))" }

    /// "Background process 0.1.0 (11)" while it answers, otherwise its state.
    public var agentLine: String {
        switch health {
        case .healthy, .updating, .waitingForUpdate:
            guard let agentVersion, let agentBuild else { return "Background process: connecting" }
            let state = health == .healthy ? "" : ", updating"
            return "Background process \(agentVersion) (\(agentBuild))\(state)"
        case .checking: return "Background process: connecting"
        case .switchedOff: return "Background process: switched off"
        case .notRunning: return "Background process: not running"
        case .damaged: return "Background process: missing from the app"
        case .failed: return "Background process: couldn’t be registered"
        }
    }

    /// What "Copy Diagnostics" puts on the pasteboard: the versions, then everything the menu shows, in full.
    public func text(_ content: MenuContent) -> String {
        var lines = [appLine, agentLine, system]
        for banner in content.banners {
            lines.append("\(banner.severity.accessibilityLabel): \(banner.title). \(banner.detail)")
        }
        if let message = content.message { lines.append([message, content.messageDetail].compactMap(\.self).joined(separator: ": ")) }
        for plan in content.plans {
            let parts = [plan.status, plan.detail, plan.destination].compactMap(\.self)
            lines.append("\(plan.name): \(parts.joined(separator: " · "))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum MenuLayout {
    /// The menu's rows (Task 17d, audit P2 and P4): problems about the whole Mac first; then a section per plan, its
    /// name as the header, its status with the detail and destination under it, its progress bar, and its own
    /// problems and actions; then the actions, Option's diagnostics, Settings and Quit.
    public static func rows(_ content: MenuContent, developer: Bool, diagnostics: MenuDiagnostics? = nil) -> [MenuRow] {
        var rows: [MenuRow] = []
        for banner in content.banners where banner.planID == nil { rows += bannerRows(banner) }
        if let message = content.message { rows.append(.item(.line(message, toolTip: content.messageDetail))) }

        for line in content.plans {
            if !rows.isEmpty { rows.append(.separator) }
            rows.append(.header(line.name))
            rows.append(.item(statusItem(line)))
            if let progress = line.progress {
                rows.append(.progress(planID: line.id, name: line.name, fraction: progress))
            } else if line.isChecking {
                rows.append(.progress(planID: line.id, name: line.name, fraction: nil))
            }
            for banner in content.banners where banner.planID == line.id { rows += bannerRows(banner) }
            if let action = line.action {
                rows.append(.item(MenuItem(action.menuTitle, symbol: .showDetails, command: .banner(action))))
            }
        }
        if !rows.isEmpty { rows.append(.separator) }

        let actions = content.actions
        let plans = actions.plans
        if !plans.isEmpty {
            let submenus = actions.perPlanSubmenus
            if actions.resume {
                rows.append(perPlan("Resume", submenus, enabled: true, all: .resumeAll, plans, \.canResume, MenuCommand.resume))
            }
            rows.append(perPlan(
                "Back Up Now", submenus, enabled: actions.backUpNow, all: .backUpAll, plans, \.canBackUp, MenuCommand.backUp))
            if actions.pause { rows.append(pauseRow(submenus, plans)) }
            if actions.cancel { rows.append(cancelRow(plans)) }
            let restorable = plans.filter(\.canRestore)
            if submenus, !restorable.isEmpty {
                rows.append(.submenu(
                    title: "Restore Files…",
                    items: restorable.map { .item(MenuItem($0.name, command: .restoreFiles($0.id))) }))
            } else if let only = restorable.first {
                rows.append(.item(MenuItem("Restore Files…", command: .restoreFiles(only.id))))
            }
            rows.append(.separator)
        }
        if let diagnostics {
            rows.append(.header("Diagnostics"))
            rows.append(.item(.line(diagnostics.appLine)))
            rows.append(.item(.line(diagnostics.agentLine)))
            rows.append(.item(MenuItem(
                "Show Last Run Log", command: diagnostics.lastLog.map(MenuCommand.showLog),
                enabled: diagnostics.lastLog != nil)))
            rows.append(.item(MenuItem("Show Logs in Finder", command: .showLogsFolder)))
            rows.append(.item(MenuItem("Copy Diagnostics", command: .copyDiagnostics)))
            rows.append(.separator)
        }
        rows.append(.item(MenuItem("Settings…", command: .settings, keyEquivalent: ",")))
        if developer { rows.append(.item(MenuItem("Developer…", command: .developer))) }
        rows.append(.item(MenuItem("Quit Restorey", command: .quit, keyEquivalent: "q")))
        return rows
    }

    /// Pause's one submenu level (HIG): the three lengths for a single plan; with several, a section header for all
    /// plans and one per plan, each with the three lengths, dimmed for a plan that can't be paused. The headers aren't
    /// read with the items under them, so each length says what it pauses for VoiceOver.
    private static func pauseRow(_ submenus: Bool, _ plans: [PlanChoice]) -> MenuRow {
        guard submenus else { return .submenu(title: "Pause", items: lengths({ .pauseAll($0) }, enabled: true, spoken: nil)) }
        var items: [MenuRow] = [.header("All Plans")] + lengths({ .pauseAll($0) }, enabled: true, spoken: "all plans")
        for plan in plans {
            items.append(.header(plan.name))
            items += lengths({ .pause(plan.id, $0) }, enabled: plan.canPause, spoken: plan.name)
        }
        return .submenu(title: "Pause", items: items)
    }

    private static func lengths(_ command: (PauseLength) -> MenuCommand, enabled: Bool, spoken: String?) -> [MenuRow] {
        PauseLength.allCases.map { length in
            .item(MenuItem(
                length.menuTitle, command: command(length), enabled: enabled,
                accessibilityLabel: spoken.map { "Pause \($0) \(length.phrase)" }))
        }
    }

    /// Cancel Backup, after Pause, only while a backup runs: a plain item for the one running, otherwise the
    /// `perPlan` shape over the running plans.
    private static func cancelRow(_ plans: [PlanChoice]) -> MenuRow {
        let running = plans.filter(\.canCancel)
        if running.count == 1, let only = running.first {
            return .item(MenuItem("Cancel Backup", command: .cancel(only.id)))
        }
        return perPlan("Cancel Backup", true, enabled: true, all: .cancelAll, running, \.canCancel, MenuCommand.cancel)
    }

    /// A plan's status: the line's status as the title, its detail and destination as the subtitle, and its state's
    /// symbol. Choosing it opens the plan in Settings, where the full detail is (its tooltip has it too).
    static func statusItem(_ line: PlanLine) -> MenuItem {
        let subtitleLines = [line.menuDetail, line.destination].compactMap(\.self).filter { !$0.isEmpty }
        let subtitle = subtitleLines.isEmpty ? nil : subtitleLines.joined(separator: "\n")
        // The severity's word first for VoiceOver, since the symbol isn't read; the plan's name, since the header
        // above isn't read with the item.
        let status = line.severity.map { "\($0.accessibilityLabel): \(line.status)" } ?? line.status
        let label = ([line.name, status] + subtitleLines).joined(separator: ", ")
        let toolTip = line.detail.flatMap { $0 == line.menuDetail ? nil : $0 }
        return MenuItem(
            line.status, subtitle: subtitle, symbol: symbol(line), toolTip: toolTip, command: .openPlan(line.id),
            accessibilityLabel: label)
    }

    private static func symbol(_ line: PlanLine) -> MenuSymbol {
        switch line.severity {
        case .error: return .error
        case .warning: return .warning
        case nil: break
        }
        if line.isPaused { return .paused }
        if line.isRunning { return .backingUp }
        return line.hasBackup ? .backedUp : .noBackup
    }

    /// A problem as an item named for its fix, with the problem under it and why it matters in its tooltip
    /// (audit P4); the off-Mac note's dismiss follows as an item of its own (audit P2: no indenting; HIG: an
    /// Option-only item mustn't be the only way to do something, so it isn't hidden behind Option).
    static func bannerRows(_ banner: MenuBanner) -> [MenuRow] {
        let symbol: MenuSymbol = banner.severity == .error ? .error : .warning
        var rows: [MenuRow] = [.item(MenuItem(
            banner.action.menuTitle, subtitle: banner.title, symbol: symbol, toolTip: banner.detail,
            command: .banner(banner.action),
            accessibilityLabel: "\(banner.severity.accessibilityLabel): \(banner.title). \(banner.action.menuTitle)"))]
        if let dismiss = banner.dismiss {
            rows.append(.item(MenuItem(dismiss.menuTitle, symbol: .dismiss, command: .banner(dismiss))))
        }
        return rows
    }

    /// Without submenus: a plain item acting on all plans. With: a submenu whose first item acts on all of them, then
    /// one item per plan. The submenu is always enabled, its items disabled when they can't act (audit P2).
    private static func perPlan(
        _ title: String, _ submenus: Bool, enabled: Bool, all: MenuCommand, _ plans: [PlanChoice],
        _ can: KeyPath<PlanChoice, Bool>, _ one: (UUID) -> MenuCommand
    ) -> MenuRow {
        guard submenus else { return .item(MenuItem(title, command: all, enabled: enabled)) }
        let each = plans.map { MenuRow.item(MenuItem($0.name, command: one($0.id), enabled: $0[keyPath: can])) }
        return .submenu(title: title, items: [.item(MenuItem("All Plans", command: all, enabled: enabled)), .separator] + each)
    }

    /// Whether an open menu showing `old` can be changed to `new` by updating its items where they are, rather than
    /// replacing them: the same rows of the same kinds, about the same plans and doing the same things. Text,
    /// subtitles, symbols, progress and whether an item is enabled may differ. Updating in place keeps the pointer's
    /// highlight and any open submenu while a backup's progress moves.
    public static func canUpdateInPlace(from old: [MenuRow], to new: [MenuRow]) -> Bool {
        old.map(\.shape) == new.map(\.shape)
    }
}

extension MenuRow {
    /// What choosing the row does: nil for one that does nothing (or only opens a submenu).
    public var command: MenuCommand? {
        if case .item(let item) = self { item.command } else { nil }
    }

    /// What a row is, without what it says.
    fileprivate var shape: Shape {
        switch self {
        case .header: .header
        case .item(let item): .item(item.command, keyEquivalent: item.keyEquivalent)
        case .progress(let id, _, _): .progress(id)
        case .submenu(let title, let items): .submenu(title, items.map(\.shape))
        case .separator: .separator
        }
    }

    fileprivate indirect enum Shape: Equatable {
        case header
        case item(MenuCommand?, keyEquivalent: String)
        case progress(UUID)
        case submenu(String, [Shape])
        case separator
    }
}
