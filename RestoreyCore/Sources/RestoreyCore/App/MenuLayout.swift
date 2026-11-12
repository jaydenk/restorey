import Foundation

/// What a menu item does when chosen.
public enum MenuCommand: Sendable, Equatable {
    /// A banner's fix, its dismiss, or a plan line's "Show Details…".
    case banner(BannerAction)
    /// A plan's lines: open Settings at that plan.
    case openPlan(UUID)
    case backUpAll
    case backUp(UUID)
    case pauseAll
    case pause(UUID)
    case resumeAll
    case resume(UUID)
    case restoreFiles(UUID)
    case settings
    /// The Debug-only developer window.
    case developer
    case quit
}

/// One item of the status item's menu, in order. The app turns each into an `NSMenuItem`; everything about which
/// items there are and what they do is decided here.
public enum MenuRow: Sendable, Equatable {
    /// A problem and its fix: choosing the banner runs `banner.action`.
    case banner(MenuBanner)
    /// A plan's name, status, detail and destination. Choosing it opens Settings at the plan.
    case plan(PlanLine)
    /// The progress bar under a running plan's line.
    case progress(planID: UUID, fraction: Double)
    /// A plain line that does nothing.
    case message(String)
    case button(title: String, command: MenuCommand, enabled: Bool = true, indented: Bool = false)
    /// `items` are buttons and separators.
    case submenu(title: String, enabled: Bool, items: [MenuRow])
    case separator
}

public enum MenuLayout {
    public static func rows(_ content: MenuContent, developer: Bool) -> [MenuRow] {
        var rows: [MenuRow] = []
        for banner in content.banners {
            rows.append(.banner(banner))
            if let dismiss = banner.dismiss {
                rows.append(.button(title: dismiss.buttonTitle, command: .banner(dismiss), indented: true))
            }
        }
        if let message = content.message { rows.append(.message(message)) }
        for line in content.plans {
            rows.append(.plan(line))
            if let progress = line.progress { rows.append(.progress(planID: line.id, fraction: progress)) }
            if let action = line.action {
                rows.append(.button(title: action.buttonTitle, command: .banner(action), indented: true))
            }
        }
        if !rows.isEmpty { rows.append(.separator) }

        let actions = content.actions
        let plans = actions.plans
        if !plans.isEmpty {
            if actions.resume {
                rows.append(perPlan("Resume", enabled: true, all: .resumeAll, plans, \.canResume, MenuCommand.resume))
            }
            rows.append(perPlan("Back Up Now", enabled: actions.backUpNow, all: .backUpAll, plans, \.canBackUp, MenuCommand.backUp))
            if actions.pause {
                rows.append(perPlan("Pause", enabled: true, all: .pauseAll, plans, \.canPause, MenuCommand.pause))
            }
            if plans.count == 1 {
                rows.append(.button(title: "Restore Files…", command: .restoreFiles(plans[0].id)))
            } else {
                rows.append(.submenu(
                    title: "Restore Files…", enabled: true,
                    items: plans.map { .button(title: $0.name, command: .restoreFiles($0.id)) }))
            }
            rows.append(.separator)
        }
        rows.append(.button(title: "Settings…", command: .settings))
        if developer { rows.append(.button(title: "Developer…", command: .developer)) }
        rows.append(.button(title: "Quit Restorey", command: .quit))
        return rows
    }

    /// One plan: a plain item. Several: a submenu whose first item acts on all of them, then one item per plan.
    private static func perPlan(
        _ title: String, enabled: Bool, all: MenuCommand, _ plans: [PlanChoice], _ can: KeyPath<PlanChoice, Bool>,
        _ one: (UUID) -> MenuCommand
    ) -> MenuRow {
        guard plans.count > 1 else { return .button(title: title, command: all, enabled: enabled) }
        let each = plans.map { MenuRow.button(title: $0.name, command: one($0.id), enabled: $0[keyPath: can]) }
        return .submenu(title: title, enabled: enabled, items: [.button(title: "All Plans", command: all), .separator] + each)
    }

    /// Whether an open menu showing `old` can be changed to `new` by updating its items where they are, rather than
    /// replacing them: the same rows of the same kinds, about the same plans and doing the same things. Text,
    /// progress and whether an item is enabled may differ. Updating in place keeps the pointer's highlight and any
    /// open submenu while a backup's progress moves.
    public static func canUpdateInPlace(from old: [MenuRow], to new: [MenuRow]) -> Bool {
        old.map(\.shape) == new.map(\.shape)
    }
}

extension MenuRow {
    /// What choosing the row does: nil for one that does nothing (or only opens a submenu).
    public var command: MenuCommand? {
        switch self {
        case .banner(let banner): .banner(banner.action)
        case .plan(let line): .openPlan(line.id)
        case .button(_, let command, _, _): command
        case .progress, .message, .submenu, .separator: nil
        }
    }

    /// What a row is, without what it says.
    fileprivate var shape: Shape {
        switch self {
        case .banner(let banner): .banner(banner.action, dismiss: banner.dismiss)
        case .plan(let line): .plan(line.id)
        case .progress(let id, _): .progress(id)
        case .message: .message
        case .button(_, let command, _, let indented): .button(command, indented: indented)
        case .submenu(let title, _, let items): .submenu(title, items.map(\.shape))
        case .separator: .separator
        }
    }

    fileprivate indirect enum Shape: Equatable {
        case banner(BannerAction, dismiss: BannerAction?)
        case plan(UUID)
        case progress(UUID)
        case message
        case button(MenuCommand, indented: Bool)
        case submenu(String, [Shape])
        case separator
    }
}
