import Foundation
import Testing
@testable import RestoreyCore

/// The rows the status item's menu is built from, and when an open menu can be updated in place.
struct MenuLayoutTests {
    private static let a = UUID()
    private static let b = UUID()

    private static func line(_ id: UUID, _ name: String, progress: Double? = nil, action: BannerAction? = nil) -> PlanLine {
        PlanLine(id: id, name: name, status: "Backing up", progress: progress, destination: "B2 · my-backups", action: action)
    }

    private static func choice(
        _ id: UUID, _ name: String, backUp: Bool = true, pause: Bool = true, resume: Bool = false, restore: Bool = true
    ) -> PlanChoice {
        PlanChoice(id: id, name: name, canBackUp: backUp, canPause: pause, canResume: resume, canRestore: restore)
    }

    private static func actions(_ plans: [PlanChoice]) -> MenuActions {
        MenuActions(
            backUpNow: plans.contains(where: \.canBackUp), pause: plans.contains(where: \.canPause),
            resume: plans.contains(where: \.canResume), perPlanSubmenus: plans.count > 1, plans: plans)
    }

    private static let tail: [MenuRow] = [
        .separator, .button(title: "Settings…", command: .settings), .button(title: "Quit Restorey", command: .quit),
    ]

    @Test func onePlanIdle() {
        let content = MenuContent(
            icon: .ok, plans: [Self.line(Self.a, "MacBook")], actions: Self.actions([Self.choice(Self.a, "MacBook")]))
        #expect(MenuLayout.rows(content, developer: false) == [
            .plan(Self.line(Self.a, "MacBook")),
            .separator,
            .button(title: "Back Up Now", command: .backUpAll),
            .button(title: "Pause", command: .pauseAll),
            .button(title: "Restore Files…", command: .restoreFiles(Self.a)),
        ] + Self.tail)
    }

    /// Back Up Now and Pause act on every plan from the submenu's first item, or on one plan below it (an
    /// item with a submenu can't have an action of its own: `NSMenu.setSubmenu(_:for:)` replaces it).
    @Test func severalPlansGetSubmenus() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos", backUp: false)]
        let content = MenuContent(
            icon: .backingUp, plans: [Self.line(Self.a, "MacBook"), Self.line(Self.b, "Photos", progress: 0.42)],
            actions: Self.actions(plans))
        #expect(MenuLayout.rows(content, developer: true) == [
            .plan(Self.line(Self.a, "MacBook")),
            .plan(Self.line(Self.b, "Photos", progress: 0.42)),
            .progress(planID: Self.b, name: "Photos", fraction: 0.42),
            .separator,
            .submenu(title: "Back Up Now", enabled: true, items: [
                .button(title: "All Plans", command: .backUpAll),
                .separator,
                .button(title: "MacBook", command: .backUp(Self.a)),
                .button(title: "Photos", command: .backUp(Self.b), enabled: false),
            ]),
            .submenu(title: "Pause", enabled: true, items: [
                .button(title: "All Plans", command: .pauseAll),
                .separator,
                .button(title: "MacBook", command: .pause(Self.a)),
                .button(title: "Photos", command: .pause(Self.b)),
            ]),
            .submenu(title: "Restore Files…", enabled: true, items: [
                .button(title: "MacBook", command: .restoreFiles(Self.a)),
                .button(title: "Photos", command: .restoreFiles(Self.b)),
            ]),
            .separator,
            .button(title: "Settings…", command: .settings),
            .button(title: "Developer…", command: .developer),
            .button(title: "Quit Restorey", command: .quit),
        ])
    }

    /// Fix round 1: an unfinished plan has no recovery kit and may have no repository, so it has nothing to restore.
    @Test func unfinishedPlansAreNotListedUnderRestoreFiles() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos", backUp: false, pause: false, restore: false)]
        let rows = MenuLayout.rows(
            MenuContent(icon: .warning, plans: [Self.line(Self.a, "MacBook"), Self.line(Self.b, "Photos")],
                        actions: Self.actions(plans)),
            developer: false)
        #expect(rows.contains(.submenu(title: "Restore Files…", enabled: true, items: [
            .button(title: "MacBook", command: .restoreFiles(Self.a)),
        ])))
        let onlyUnfinished = MenuLayout.rows(
            MenuContent(icon: .warning, plans: [Self.line(Self.b, "Photos")],
                        actions: Self.actions([Self.choice(Self.b, "Photos", backUp: false, pause: false, restore: false)])),
            developer: false)
        #expect(!onlyUnfinished.contains { if case .button(_, .restoreFiles, _, _) = $0 { true } else { false } })
    }

    /// Fix round 1: whether the actions get submenus is `perPlanSubmenus`, decided once by `MenuPresentation`.
    @Test func submenusFollowPerPlanSubmenus() {
        var actions = Self.actions([Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos")])
        actions.perPlanSubmenus = false
        let rows = MenuLayout.rows(MenuContent(icon: .ok, actions: actions), developer: false)
        #expect(rows.contains(.button(title: "Back Up Now", command: .backUpAll)))
        #expect(rows.contains(.button(title: "Pause", command: .pauseAll)))
    }

    @Test func pausedOffersResumeFirstAndNoPause() {
        let content = MenuContent(
            icon: .paused, plans: [Self.line(Self.a, "MacBook")],
            actions: Self.actions([Self.choice(Self.a, "MacBook", pause: false, resume: true)]))
        let rows = MenuLayout.rows(content, developer: false)
        #expect(Array(rows[2...4]) == [
            .button(title: "Resume", command: .resumeAll),
            .button(title: "Back Up Now", command: .backUpAll),
            .button(title: "Restore Files…", command: .restoreFiles(Self.a)),
        ])
    }

    /// A banner's fix is the banner itself; the off-Mac note's dismiss and a failed line's "Show Details…" sit
    /// under them.
    @Test func bannersMessagesAndLineActions() {
        let note = MenuBanner(
            severity: .warning, title: "No off-Mac monitoring", detail: "Add a check-in URL.",
            action: .addCheckInURL(Self.a), dismiss: .dismissOffMacNote(Self.a))
        let failed = Self.line(Self.a, "MacBook", action: .showDetails(Self.a))
        let content = MenuContent(
            icon: .error, banners: [note], plans: [failed], actions: Self.actions([Self.choice(Self.a, "MacBook")]),
            message: "Last known: backed up at 13:16")
        let rows = MenuLayout.rows(content, developer: false)
        #expect(Array(rows[0...4]) == [
            .banner(note),
            .button(title: "Don’t Show This Again", command: .banner(.dismissOffMacNote(Self.a)), indented: true),
            .message("Last known: backed up at 13:16"),
            .plan(failed),
            .button(title: "Show Details…", command: .banner(.showDetails(Self.a)), indented: true),
        ])
    }

    /// The agent isn't running: no plan actions (there is no one to ask), just the fix, Settings and Quit.
    @Test func noActionsWithoutPlans() {
        let banner = MenuBanner(
            severity: .error, title: "Backups aren’t running", detail: "No backups will happen.",
            action: .restartAgent)
        let content = MenuContent(icon: .error, banners: [banner], message: "Last known: backed up at 13:16")
        #expect(MenuLayout.rows(content, developer: false) == [
            .banner(banner), .message("Last known: backed up at 13:16"),
        ] + Self.tail)
    }

    @Test func emptyContentHasJustTheTail() {
        #expect(MenuLayout.rows(MenuContent(icon: .ok), developer: false)
            == [.button(title: "Settings…", command: .settings), .button(title: "Quit Restorey", command: .quit)])
    }

    /// What choosing each kind of row does: a banner runs its fix, a plan's lines open Settings at that plan.
    @Test func whatEachRowDoes() {
        let banner = MenuBanner(severity: .error, title: "t", detail: "d", action: .openFullDiskAccess)
        #expect(MenuRow.banner(banner).command == .banner(.openFullDiskAccess))
        #expect(MenuRow.plan(Self.line(Self.a, "MacBook")).command == .openPlan(Self.a))
        #expect(MenuRow.button(title: "Back Up Now", command: .backUpAll).command == .backUpAll)
        for row: MenuRow in [.message("m"), .separator, .progress(planID: Self.a, name: "MacBook", fraction: 0.5),
                             .submenu(title: "Pause", enabled: true, items: [])] {
            #expect(row.command == nil, "\(row)")
        }
    }

    @Test func buttonTitles() {
        let id = Self.a
        #expect(BannerAction.openFullDiskAccess.buttonTitle == "Open System Settings")
        #expect(BannerAction.restartAgent.buttonTitle == "Restart Backups")
        #expect(BannerAction.openLoginItems.buttonTitle == "Open System Settings")
        #expect(BannerAction.turnOnNotifications.buttonTitle == "Open System Settings")
        #expect(BannerAction.addCheckInURL(id).buttonTitle == "Add…")
        #expect(BannerAction.dismissOffMacNote(id).buttonTitle == "Don’t Show This Again")
        #expect(BannerAction.finishSetup(id).buttonTitle == "Finish Setup…")
        #expect(BannerAction.saveRecoveryKit(id).buttonTitle == "Save Recovery Kit…")
        #expect(BannerAction.showDetails(id).buttonTitle == "Show Details…")
    }

    // MARK: Updating an open menu

    /// Progress moving, text changing and items enabling keep the shape, so the open menu's items are updated
    /// where they are (the pointer's highlight and an open submenu survive).
    @Test func changesOfTextAndProgressUpdateInPlace() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos")]
        let before = MenuContent(
            icon: .backingUp, plans: [Self.line(Self.a, "MacBook", progress: 0.1), Self.line(Self.b, "Photos")],
            actions: Self.actions(plans))
        var after = before
        after.plans[0].progress = 0.6
        after.plans[0].detail = "1.2 of 2.9 GB · ~6 min · 18 MB/s"
        after.plans[1].status = "Backed up at 14:16"
        after.actions.plans[0].canBackUp = false
        #expect(MenuLayout.canUpdateInPlace(
            from: MenuLayout.rows(before, developer: false), to: MenuLayout.rows(after, developer: false)))
    }

    /// A row appearing or going (a progress bar at a backup's start, a banner, a plan) rebuilds the menu.
    @Test func addedOrRemovedRowsRebuild() {
        let plans = [Self.choice(Self.a, "MacBook")]
        let idle = MenuContent(icon: .ok, plans: [Self.line(Self.a, "MacBook")], actions: Self.actions(plans))
        var running = idle
        running.plans[0].progress = 0
        var bannered = idle
        bannered.banners = [MenuBanner(
            severity: .warning, title: "Notifications are off — Restorey can’t alert you", detail: "",
            action: .turnOnNotifications)]
        var resumable = idle
        resumable.actions.plans[0].canResume = true
        resumable.actions.resume = true
        let rows = MenuLayout.rows(idle, developer: false)
        for other in [running, bannered, resumable] {
            #expect(!MenuLayout.canUpdateInPlace(from: rows, to: MenuLayout.rows(other, developer: false)))
        }
        #expect(MenuLayout.canUpdateInPlace(from: rows, to: rows))
    }

    /// Another plan in a line's place (same shape, different ID) rebuilds, so an item never keeps a stale target.
    @Test func aDifferentPlanRebuilds() {
        let one = MenuContent(icon: .ok, plans: [Self.line(Self.a, "MacBook")], actions: Self.actions([Self.choice(Self.a, "MacBook")]))
        let other = MenuContent(icon: .ok, plans: [Self.line(Self.b, "MacBook")], actions: Self.actions([Self.choice(Self.b, "MacBook")]))
        #expect(!MenuLayout.canUpdateInPlace(
            from: MenuLayout.rows(one, developer: false), to: MenuLayout.rows(other, developer: false)))
    }
}
