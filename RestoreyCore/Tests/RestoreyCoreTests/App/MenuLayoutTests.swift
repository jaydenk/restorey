import Foundation
import Testing
@testable import RestoreyCore

/// The rows the status item's menu is built from (Task 17d: a section per plan, standard items with subtitles and
/// symbols, Option's diagnostics), and when an open menu can be updated in place.
struct MenuLayoutTests {
    private static let a = UUID()
    private static let b = UUID()

    private static func line(
        _ id: UUID, _ name: String, status: String = "Backed up at 14:16", menuDetail: String? = "Next 15:16",
        progress: Double? = nil, action: BannerAction? = nil, running: Bool = false
    ) -> PlanLine {
        PlanLine(
            id: id, name: name, status: status, detail: menuDetail, menuDetail: menuDetail, progress: progress,
            destination: "B2 · my-backups", action: action, isRunning: running, hasBackup: true)
    }

    private static func choice(
        _ id: UUID, _ name: String, backUp: Bool = true, pause: Bool? = nil, resume: Bool = false, restore: Bool = true,
        cancel: Bool = false
    ) -> PlanChoice {
        // As `MenuPresentation` decides it, a plan can be paused exactly when it can be cancelled: while it backs up.
        PlanChoice(
            id: id, name: name, canBackUp: backUp, canPause: pause ?? cancel, canResume: resume, canRestore: restore,
            canCancel: cancel)
    }

    private static func actions(_ plans: [PlanChoice]) -> MenuActions {
        MenuActions(
            backUpNow: plans.contains(where: \.canBackUp), pause: plans.contains(where: \.canPause),
            resume: plans.contains(where: \.canResume), cancel: plans.contains(where: \.canCancel),
            perPlanSubmenus: plans.count > 1, plans: plans)
    }

    private static func button(_ title: String, _ command: MenuCommand, enabled: Bool = true) -> MenuRow {
        .item(MenuItem(title, command: command, enabled: enabled))
    }

    /// Pause's three lengths for one plan or all: the menu's titles, each doing `command` for its length.
    private static func lengths(
        _ command: (PauseLength) -> MenuCommand, enabled: Bool = true, label: String? = nil
    ) -> [MenuRow] {
        let titles = ["For 1 Hour", "For 4 Hours", "Until Tomorrow"]
        let spoken = ["for 1 hour", "for 4 hours", "until tomorrow"]
        return zip(PauseLength.allCases, zip(titles, spoken)).map { length, words in
            .item(MenuItem(
                words.0, command: command(length), enabled: enabled, accessibilityLabel: label.map { "Pause \($0) \(words.1)" }))
        }
    }

    private static let settings = MenuRow.item(MenuItem("Settings…", command: .settings, keyEquivalent: ","))
    private static let quit = MenuRow.item(MenuItem("Quit Restorey", command: .quit, keyEquivalent: "q"))
    private static let tail: [MenuRow] = [.separator, settings, quit]

    @Test func onePlanIdle() {
        let content = MenuContent(
            icon: .ok, plans: [Self.line(Self.a, "MacBook")], actions: Self.actions([Self.choice(Self.a, "MacBook")]))
        #expect(MenuLayout.rows(content, developer: false) == [
            .header("MacBook"),
            .item(MenuItem(
                "Backed up at 14:16", subtitle: "Next 15:16\nB2 · my-backups", symbol: .backedUp,
                command: .openPlan(Self.a), accessibilityLabel: "MacBook, Backed up at 14:16, Next 15:16, B2 · my-backups")),
            .separator,
            Self.button("Back Up Now", .backUpAll),
            Self.button("Restore Files…", .restoreFiles(Self.a)),
        ] + Self.tail)
    }

    /// Each plan is a section of its own, its name the header. Back Up Now and Pause act on every plan from the
    /// submenu's first item, or on one plan below it (an item with a submenu can't have an action of its own).
    @Test func severalPlansGetSectionsAndSubmenus() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos", backUp: false, cancel: true)]
        let photos = Self.line(Self.b, "Photos", status: "Backing up", menuDetail: nil, progress: 0.42, running: true)
        let content = MenuContent(
            icon: .backingUp, plans: [Self.line(Self.a, "MacBook"), photos], actions: Self.actions(plans))
        let rows = MenuLayout.rows(content, developer: true)
        #expect(rows.count == 15)
        #expect(Array(rows[2...5]) == [
            .separator,
            .header("Photos"),
            .item(MenuItem(
                "Backing up", subtitle: "B2 · my-backups", symbol: .backingUp, command: .openPlan(Self.b),
                accessibilityLabel: "Photos, Backing up, B2 · my-backups")),
            .progress(planID: Self.b, name: "Photos", fraction: 0.42),
        ])
        #expect(Array(rows[6...]) == [
            .separator,
            .submenu(title: "Back Up Now", items: [
                Self.button("All Plans", .backUpAll),
                .separator,
                Self.button("MacBook", .backUp(Self.a)),
                Self.button("Photos", .backUp(Self.b), enabled: false),
            ]),
            .submenu(title: "Pause", items: Self.lengths({ .pause(Self.b, $0) }, label: "Photos")),
            Self.button("Cancel Backup", .cancel(Self.b)),
            .submenu(title: "Restore Files…", items: [
                Self.button("MacBook", .restoreFiles(Self.a)),
                Self.button("Photos", .restoreFiles(Self.b)),
            ]),
            .separator,
            Self.settings,
            Self.button("Developer…", .developer),
            Self.quit,
        ])
    }

    /// Pause with several plans backing up: a section header for all of them and for each running plan, each with the
    /// three lengths. A plan that isn't backing up isn't listed (owner, 20 Nov 2026: nothing to pause).
    @Test func pauseListsEachLengthUnderAllPlansAndUnderEachRunningPlan() {
        let plans = [
            Self.choice(Self.a, "MacBook", backUp: false, cancel: true),
            Self.choice(Self.b, "Photos", backUp: false, cancel: true),
            Self.choice(UUID(), "Idle"),
        ]
        let rows = MenuLayout.rows(MenuContent(icon: .backingUp, actions: Self.actions(plans)), developer: false)
        #expect(rows.contains(.submenu(title: "Pause", items:
            [MenuRow.header("All Plans")] + Self.lengths({ .pauseAll($0) }, label: "all plans")
            + [.header("MacBook")] + Self.lengths({ .pause(Self.a, $0) }, label: "MacBook")
            + [.header("Photos")] + Self.lengths({ .pause(Self.b, $0) }, label: "Photos"))))
    }

    /// With nothing backing up there is no Pause at all, as there is no Cancel Backup.
    @Test func pauseAppearsOnlyWhileABackupRuns() {
        let idle = MenuLayout.rows(
            MenuContent(icon: .ok, actions: Self.actions([Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos")])),
            developer: false)
        #expect(!idle.contains { if case .submenu(let title, _) = $0 { title == "Pause" } else { false } })
    }

    /// Cancel Backup is there only while a backup runs, after Pause.
    @Test func cancelBackupAppearsOnlyWhileABackupRuns() {
        let idle = MenuLayout.rows(
            MenuContent(icon: .ok, actions: Self.actions([Self.choice(Self.a, "MacBook")])), developer: false)
        #expect(!idle.contains { if case .item(let item) = $0 { item.title == "Cancel Backup" } else { false } })

        let running = MenuLayout.rows(
            MenuContent(icon: .backingUp, actions: Self.actions([Self.choice(Self.a, "MacBook", backUp: false, cancel: true)])),
            developer: false)
        #expect(running == [
            Self.button("Back Up Now", .backUpAll, enabled: false),
            .submenu(title: "Pause", items: Self.lengths { .pauseAll($0) }),
            Self.button("Cancel Backup", .cancel(Self.a)),
            Self.button("Restore Files…", .restoreFiles(Self.a)),
        ] + Self.tail)
    }

    /// Several plans, one running: a plain item for that plan, with no submenu to choose from.
    @Test func cancelBackupIsAPlainItemWhenOnlyOneOfSeveralPlansRuns() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos", backUp: false, cancel: true)]
        let rows = MenuLayout.rows(MenuContent(icon: .backingUp, actions: Self.actions(plans)), developer: false)
        #expect(rows.contains(Self.button("Cancel Backup", .cancel(Self.b))))
        #expect(!rows.contains { if case .submenu(let title, _) = $0 { title == "Cancel Backup" } else { false } })
        let pause = rows.firstIndex { if case .submenu(let title, _) = $0 { title == "Pause" } else { false } }
        #expect(pause.map { rows[$0 + 1] } == Self.button("Cancel Backup", .cancel(Self.b)))
    }

    /// Several running: a submenu with All Plans, a separator, and an item per running plan only.
    @Test func cancelBackupIsASubmenuWhenSeveralPlansRun() {
        let plans = [
            Self.choice(Self.a, "MacBook", backUp: false, cancel: true),
            Self.choice(Self.b, "Photos", backUp: false, cancel: true),
            Self.choice(UUID(), "Idle"),
        ]
        let rows = MenuLayout.rows(MenuContent(icon: .backingUp, actions: Self.actions(plans)), developer: false)
        #expect(rows.contains(.submenu(title: "Cancel Backup", items: [
            Self.button("All Plans", .cancelAll),
            .separator,
            Self.button("MacBook", .cancel(Self.a)),
            Self.button("Photos", .cancel(Self.b)),
        ])))
    }

    @Test func eachPauseLengthHasItsMenuTitleAndWords() {
        #expect(PauseLength.allCases.map(\.menuTitle) == ["For 1 Hour", "For 4 Hours", "Until Tomorrow"])
        #expect(PauseLength.allCases.map(\.phrase) == ["for 1 hour", "for 4 hours", "until tomorrow"])
    }

    /// Audit P2: a submenu stays available when nothing in it can be chosen; its items are disabled instead.
    @Test func aSubmenuStaysAvailableWhenNoneOfItsItemsCan() {
        let plans = [Self.choice(Self.a, "MacBook", backUp: false), Self.choice(Self.b, "Photos", backUp: false)]
        let rows = MenuLayout.rows(MenuContent(icon: .backingUp, actions: Self.actions(plans)), developer: false)
        #expect(rows.contains(.submenu(title: "Back Up Now", items: [
            Self.button("All Plans", .backUpAll, enabled: false),
            .separator,
            Self.button("MacBook", .backUp(Self.a), enabled: false),
            Self.button("Photos", .backUp(Self.b), enabled: false),
        ])))
    }

    /// Fix round 1: an unfinished plan has no recovery kit and may have no repository, so it has nothing to restore.
    @Test func unfinishedPlansAreNotListedUnderRestoreFiles() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos", backUp: false, pause: false, restore: false)]
        let rows = MenuLayout.rows(
            MenuContent(icon: .warning, plans: [Self.line(Self.a, "MacBook"), Self.line(Self.b, "Photos")],
                        actions: Self.actions(plans)),
            developer: false)
        #expect(rows.contains(.submenu(title: "Restore Files…", items: [Self.button("MacBook", .restoreFiles(Self.a))])))
        let onlyUnfinished = MenuLayout.rows(
            MenuContent(icon: .warning, plans: [Self.line(Self.b, "Photos")],
                        actions: Self.actions([Self.choice(Self.b, "Photos", backUp: false, pause: false, restore: false)])),
            developer: false)
        #expect(!onlyUnfinished.contains { if case .restoreFiles = $0.command { true } else { false } })
    }

    /// Fix round 1: whether the actions get submenus is `perPlanSubmenus`, decided once by `MenuPresentation`.
    @Test func submenusFollowPerPlanSubmenus() {
        var actions = Self.actions([Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos", cancel: true)])
        actions.perPlanSubmenus = false
        let rows = MenuLayout.rows(MenuContent(icon: .ok, actions: actions), developer: false)
        #expect(rows.contains(Self.button("Back Up Now", .backUpAll)))
        #expect(rows.contains(.submenu(title: "Pause", items: Self.lengths { .pauseAll($0) })))
    }

    @Test func pausedOffersResumeFirstAndNoPause() {
        let paused = PlanLine(
            id: Self.a, name: "MacBook", status: "Paused", detail: "Resumes by itself at 15:00",
            menuDetail: "Resumes by itself at 15:00", destination: "B2 · my-backups", isPaused: true, hasBackup: true)
        let content = MenuContent(
            icon: .paused, plans: [paused],
            actions: Self.actions([Self.choice(Self.a, "MacBook", pause: false, resume: true)]))
        let rows = MenuLayout.rows(content, developer: false)
        #expect(rows[1] == .item(MenuItem(
            "Paused", subtitle: "Resumes by itself at 15:00\nB2 · my-backups", symbol: .paused, command: .openPlan(Self.a),
            accessibilityLabel: "MacBook, Paused, Resumes by itself at 15:00, B2 · my-backups")))
        #expect(Array(rows[3...5]) == [
            Self.button("Resume", .resumeAll),
            Self.button("Back Up Now", .backUpAll),
            Self.button("Restore Files…", .restoreFiles(Self.a)),
        ])
    }

    /// Audit P2 and P4: a problem about the whole Mac is at the top; one about a plan is in that plan's section. Each
    /// is an item named for its fix, with the problem as its subtitle and why it matters as its tooltip. The off-Mac
    /// note's dismiss and a failed plan's "Show Details…" are items of their own in the section, never indented.
    @Test func bannersAndPlanActionsSitInTheirSections() {
        let fda = MenuBanner(
            severity: .error, title: "Full Disk Access is missing", detail: "Backups would be empty.",
            action: .openFullDiskAccess)
        let note = MenuBanner(
            severity: .warning, title: "No off-Mac monitoring", detail: "Add a check-in URL so you hear if this Mac stops.",
            action: .addCheckInURL(Self.a), dismiss: .dismissOffMacNote(Self.a), planID: Self.a)
        let failed = PlanLine(
            id: Self.a, name: "MacBook", status: "Backup failed at 14:16", detail: "Fatal: unable to open config file",
            destination: "B2 · my-backups", severity: .error, action: .showDetails(Self.a), hasBackup: true)
        let content = MenuContent(
            icon: .error, banners: [fda, note], plans: [failed], actions: Self.actions([Self.choice(Self.a, "MacBook")]))
        let rows = MenuLayout.rows(content, developer: false)
        #expect(Array(rows[0...6]) == [
            .item(MenuItem(
                "Allow Full Disk Access…", subtitle: "Full Disk Access is missing", symbol: .error,
                toolTip: "Backups would be empty.", command: .banner(.openFullDiskAccess),
                accessibilityLabel: "Error: Full Disk Access is missing. Allow Full Disk Access…")),
            .separator,
            .header("MacBook"),
            .item(MenuItem(
                "Backup failed at 14:16", subtitle: "B2 · my-backups", symbol: .error,
                toolTip: "Fatal: unable to open config file", command: .openPlan(Self.a),
                accessibilityLabel: "MacBook, Error: Backup failed at 14:16, B2 · my-backups")),
            .item(MenuItem(
                "Add Check-In URL…", subtitle: "No off-Mac monitoring", symbol: .warning,
                toolTip: "Add a check-in URL so you hear if this Mac stops.", command: .banner(.addCheckInURL(Self.a)),
                accessibilityLabel: "Warning: No off-Mac monitoring. Add Check-In URL…")),
            .item(MenuItem("Don’t Show This Again", symbol: .dismiss, command: .banner(.dismissOffMacNote(Self.a)))),
            .item(MenuItem("Show Details…", symbol: .showDetails, command: .banner(.showDetails(Self.a)))),
        ])
        #expect(rows[7] == .separator)
    }

    /// The agent isn't running: no plan actions (there is no one to ask), just the fix, the last known backup,
    /// Settings and Quit.
    @Test func noActionsWithoutPlans() {
        let banner = MenuBanner(
            severity: .error, title: "Backups aren’t running", detail: "No backups will happen.", action: .restartAgent)
        let content = MenuContent(icon: .error, banners: [banner], message: "Last known: backed up at 13:16")
        #expect(MenuLayout.rows(content, developer: false) == [
            .item(MenuItem(
                "Restart Backups", subtitle: "Backups aren’t running", symbol: .error, toolTip: "No backups will happen.",
                command: .banner(.restartAgent), accessibilityLabel: "Error: Backups aren’t running. Restart Backups")),
            .item(.line("Last known: backed up at 13:16")),
        ] + Self.tail)
    }

    /// A banner with no fix (the backup a repair stopped) is a line that says so, its detail under it.
    @Test func aBannerWithoutAFixIsALine() {
        let banner = MenuBanner(
            severity: .warning, title: "Restorey restarted its background process, which hadn’t answered for 30 minutes",
            detail: "The backup that was running was stopped and will run again at its next time.", action: nil)
        #expect(MenuLayout.bannerRows(banner) == [.item(MenuItem(
            "Restorey restarted its background process, which hadn’t answered for 30 minutes",
            subtitle: "The backup that was running was stopped and will run again at its next time.", symbol: .warning,
            enabled: false,
            accessibilityLabel: "Warning: Restorey restarted its background process, which hadn’t answered for 30 minutes. "
                + "The backup that was running was stopped and will run again at its next time."))])
    }

    /// A message's full sentence is its tooltip (audit P5).
    @Test func aMessageCarriesItsDetailAsATooltip() {
        let content = MenuContent(icon: .error, message: "Backups couldn’t be set up", messageDetail: "It failed: because.")
        #expect(MenuLayout.rows(content, developer: false).first
            == .item(MenuItem("Backups couldn’t be set up", toolTip: "It failed: because.", enabled: false)))
    }

    @Test func emptyContentHasJustTheTail() {
        #expect(MenuLayout.rows(MenuContent(icon: .ok), developer: false) == [Self.settings, Self.quit])
    }

    // MARK: Status items

    /// The symbol follows the plan's state; the tooltip is the full detail only when the menu shows less of it.
    @Test func statusItemSymbolsAndTooltips() {
        func item(_ line: PlanLine) -> MenuItem { MenuLayout.statusItem(line) }
        var line = PlanLine(id: Self.a, name: "MacBook", status: "No backup yet", destination: nil)
        #expect(item(line).symbol == .noBackup)
        #expect(item(line).subtitle == nil)
        #expect(item(line).accessibilityLabel == "MacBook, No backup yet")
        line.hasBackup = true
        #expect(item(line).symbol == .backedUp)
        line.isRunning = true
        #expect(item(line).symbol == .backingUp)
        line.severity = .warning
        #expect(item(line).symbol == .warning)
        line.detail = "Skipped while on battery · 3 files couldn’t be read"
        line.menuDetail = "Skipped while on battery (+1 more)"
        #expect(item(line).toolTip == "Skipped while on battery · 3 files couldn’t be read")
        line.menuDetail = line.detail
        #expect(item(line).toolTip == nil)
    }

    @Test func symbolNames() {
        #expect(MenuSymbol.backedUp.symbolName == "checkmark.circle")
        #expect(MenuSymbol.noBackup.symbolName == "circle.dashed")
        #expect(MenuSymbol.backingUp.symbolName == "arrow.up.circle")
        #expect(MenuSymbol.paused.symbolName == "pause.circle")
        #expect(MenuSymbol.warning.symbolName == "exclamationmark.triangle.fill")
        #expect(MenuSymbol.error.symbolName == "xmark.octagon.fill")
        #expect(MenuSymbol.showDetails.symbolName == "clock.arrow.circlepath")
        #expect(MenuSymbol.dismiss.symbolName == "eye.slash")
        #expect(MenuSymbol.warning.severity == .warning)
        #expect(MenuSymbol.error.severity == .error)
        #expect(MenuSymbol.backedUp.severity == nil)
    }

    // MARK: Option's diagnostics

    private static let diagnostics = MenuDiagnostics(
        appVersion: "0.1.0", appBuild: "11", health: .healthy, agentVersion: "0.1.0", agentBuild: "11",
        lastLog: "runs/2026-11-12/a.log", system: "macOS Version 27.2 (Build 27C60)")

    /// Audit T1: Option-click adds a Diagnostics section before Settings; nothing in it changes a backup.
    @Test func diagnosticsSection() {
        let rows = MenuLayout.rows(MenuContent(icon: .ok), developer: false, diagnostics: Self.diagnostics)
        #expect(rows == [
            .header("Diagnostics"),
            .item(.line("Restorey 0.1.0 (11)")),
            .item(.line("Background process 0.1.0 (11)")),
            Self.button("Show Last Run Log", .showLog("runs/2026-11-12/a.log")),
            Self.button("Show Logs in Finder", .showLogsFolder),
            Self.button("Copy Diagnostics", .copyDiagnostics),
            .separator,
            Self.settings,
            Self.quit,
        ])
        var none = Self.diagnostics
        none.lastLog = nil
        #expect(MenuLayout.rows(MenuContent(icon: .ok), developer: false, diagnostics: none)[3]
            == .item(MenuItem("Show Last Run Log", command: nil, enabled: false)))
    }

    @Test func diagnosticsAgentLine() {
        var d = Self.diagnostics
        let expected: [(AgentHealthState, String)] = [
            (.healthy, "Background process 0.1.0 (11)"),
            (.updating, "Background process 0.1.0 (11), updating"),
            (.checking, "Background process: connecting"),
            (.switchedOff, "Background process: switched off"),
            (.notRunning(reachable: false), "Background process: not running"),
            (.damaged, "Background process: missing from the app"),
            (.failed("x"), "Background process: couldn’t be registered"),
            (.signatureUntrusted, "Background process: not contacted, as the app’s signature can’t be verified"),
        ]
        for (health, line) in expected {
            d.health = health
            #expect(d.agentLine == line, "\(health)")
        }
        d.health = .healthy
        d.agentVersion = nil
        #expect(d.agentLine == "Background process: connecting")
    }

    @Test func copiedDiagnosticsText() {
        let banner = MenuBanner(
            severity: .warning, title: "Notifications are off", detail: "Turn them on.", action: .turnOnNotifications)
        let line = PlanLine(
            id: Self.a, name: "MacBook", status: "Backed up at 14:16", detail: "Next 15:16", destination: "B2 · my-backups")
        let text = Self.diagnostics.text(MenuContent(icon: .warning, banners: [banner], plans: [line]))
        #expect(text == """
            Restorey 0.1.0 (11)
            Background process 0.1.0 (11)
            macOS Version 27.2 (Build 27C60)
            Warning: Notifications are off. Turn them on.
            MacBook: Backed up at 14:16 · Next 15:16 · B2 · my-backups
            """)
    }

    @Test func lastLogIsTheNewestRunWithALog() {
        let plan = Plan.newHotPlan(
            name: "MacBook", repository: .raw(repository: "/tmp/r", environmentNames: []), origin: .created,
            hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: Date(timeIntervalSince1970: 0))
        func record(_ end: TimeInterval, _ log: String) -> RunRecord {
            RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
                startedAt: Date(timeIntervalSince1970: end - 1), endedAt: Date(timeIntervalSince1970: end),
                outcome: .unchanged, summary: nil, logFile: log)
        }
        func status(_ record: RunRecord) -> PlanStatus {
            PlanStatus(plan: plan, phase: .idle, lastRecord: record, nextRunAt: nil, alerts: [])
        }
        let agent = AgentStatus(
            plans: [status(record(10, "runs/old.log")), status(record(20, "runs/new.log")), status(record(30, ""))],
            configError: nil, fdaMissing: false, generatedAt: Date(timeIntervalSince1970: 40))
        #expect(MenuDiagnostics.lastLog(agent) == "runs/new.log")
        #expect(MenuDiagnostics.lastLog(nil) == nil)
    }

    // MARK: Words

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
        #expect(BannerAction.showSettingsError.buttonTitle == "Show in Settings…")
    }

    /// The menu names each fix as a command (audit P4).
    @Test func menuTitles() {
        let id = Self.a
        #expect(BannerAction.openFullDiskAccess.menuTitle == "Allow Full Disk Access…")
        #expect(BannerAction.restartAgent.menuTitle == "Restart Backups")
        #expect(BannerAction.openLoginItems.menuTitle == "Turn On in Login Items…")
        #expect(BannerAction.turnOnNotifications.menuTitle == "Turn On Notifications…")
        #expect(BannerAction.addCheckInURL(id).menuTitle == "Add Check-In URL…")
        #expect(BannerAction.dismissOffMacNote(id).menuTitle == "Don’t Show This Again")
        #expect(BannerAction.finishSetup(id).menuTitle == "Finish Setup…")
        #expect(BannerAction.setUp.menuTitle == "Finish Setup…")
        #expect(BannerAction.saveRecoveryKit(id).menuTitle == "Save Recovery Kit…")
        #expect(BannerAction.showDetails(id).menuTitle == "Show Details…")
        #expect(BannerAction.showSettingsError.menuTitle == "Show in Settings…")
    }

    /// What choosing each kind of row does.
    @Test func whatEachRowDoes() {
        #expect(MenuRow.item(MenuItem("t", command: .backUpAll)).command == .backUpAll)
        for row: MenuRow in [.item(.line("m")), .separator, .header("MacBook"),
                             .progress(planID: Self.a, name: "MacBook", fraction: 0.5), .submenu(title: "Pause", items: [])] {
            #expect(row.command == nil, "\(row)")
        }
    }

    // MARK: Updating an open menu

    /// Progress moving, text and subtitles changing and items enabling keep the shape, so the open menu's items are
    /// updated where they are (the pointer's highlight and an open submenu survive).
    @Test func changesOfTextAndProgressUpdateInPlace() {
        let plans = [Self.choice(Self.a, "MacBook"), Self.choice(Self.b, "Photos")]
        let before = MenuContent(
            icon: .backingUp,
            plans: [Self.line(Self.a, "MacBook", progress: 0.1, running: true), Self.line(Self.b, "Photos")],
            actions: Self.actions(plans))
        var after = before
        after.plans[0].progress = 0.6
        after.plans[0].menuDetail = "1.2 of 2.9 GB · ~6 min"
        after.plans[1].status = "Backed up at 14:16"
        after.plans[1].severity = .warning
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
            severity: .warning, title: "Notifications are off", detail: "", action: .turnOnNotifications)]
        var resumable = idle
        resumable.actions.plans[0].canResume = true
        resumable.actions.resume = true
        let rows = MenuLayout.rows(idle, developer: false)
        for other in [running, bannered, resumable] {
            #expect(!MenuLayout.canUpdateInPlace(from: rows, to: MenuLayout.rows(other, developer: false)))
        }
        #expect(!MenuLayout.canUpdateInPlace(
            from: rows, to: MenuLayout.rows(idle, developer: false, diagnostics: Self.diagnostics)))
        #expect(MenuLayout.canUpdateInPlace(from: rows, to: rows))
    }

    /// Another plan in a section's place (same shape, different ID) rebuilds, so an item never keeps a stale target.
    @Test func aDifferentPlanRebuilds() {
        let one = MenuContent(icon: .ok, plans: [Self.line(Self.a, "MacBook")], actions: Self.actions([Self.choice(Self.a, "MacBook")]))
        let other = MenuContent(icon: .ok, plans: [Self.line(Self.b, "MacBook")], actions: Self.actions([Self.choice(Self.b, "MacBook")]))
        #expect(!MenuLayout.canUpdateInPlace(
            from: MenuLayout.rows(one, developer: false), to: MenuLayout.rows(other, developer: false)))
    }
}
