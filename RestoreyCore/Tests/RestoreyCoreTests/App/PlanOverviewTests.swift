import Foundation
import Testing
@testable import RestoreyCore

/// A plan's Overview tab in Settings (Task 14c, owner 15 Nov 2026; layout ruling R1): a headline with the plan's state
/// only ("Up to date", "Backing up — 42%", "Backup failed", …) and the menu's reason where there is one, then the times,
/// only in the Last backup and Next backup rows ("Today at 17:10"), and the menu's actions, enabled as its items are.
/// Brisbane time, en-AU.
struct PlanOverviewTests {
    private static let locale = Locale(identifier: "en_AU")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        calendar.locale = locale
        return calendar
    }()

    private static func at(_ hour: Int, _ minute: Int, day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private static let now = at(14, 20)

    private static func plan(setup: Bool = true, kit: Bool = true, checkIn: Bool = true) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Local · repo", repository: .raw(repository: "/Users/me/restorey-test/repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        plan.hasCheckInURL = checkIn
        plan.setupCompletedAt = setup ? now : nil
        plan.recoveryKitConfirmedAt = kit && setup ? now : nil
        plan.noSuccessAlertDays = 3
        return plan
    }

    private static func record(_ plan: Plan, _ outcome: RunOutcome, at end: Date) -> RunRecord {
        RunRecord(
            id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
            startedAt: end.addingTimeInterval(-60), endedAt: end, outcome: outcome, summary: nil, logFile: "")
    }

    private static func status(
        _ plan: Plan = plan(), phase: PlanPhase = .idle, backup: RunOutcome? = .success(snapshotID: "a"),
        backedUpAt: Date = at(14, 16), failed: RunOutcome? = nil, failedAt: Date = at(14, 18), next: Date? = at(15, 16),
        alerts: [AlertCondition] = [], verdictKnown: Bool = true
    ) -> PlanStatus {
        let good = backup.map { record(plan, $0, at: backedUpAt) }
        let bad = failed.map { record(plan, $0, at: failedAt) }
        let verdict = verdictKnown ? bad ?? good : nil
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: bad ?? good, nextRunAt: next, alerts: alerts, lastBackup: good,
            latestBackupRecord: verdict, latestBackupVerdict: verdict)
    }

    private static func overview(_ plan: PlanStatus, health: AgentHealthState = .healthy) -> PlanOverview {
        MenuPresentation.overview(
            planID: plan.plan.id, health: health,
            status: AgentStatus(plans: [plan], configError: nil, fdaMissing: false, generatedAt: now),
            notificationsAuthorised: true, now: now, calendar: calendar, locale: locale)!
    }

    private static func menuLine(_ plan: PlanStatus) -> PlanLine {
        MenuPresentation.planLine(for: plan, now: now, calendar: calendar, locale: locale)
    }

    private static func enabled(_ overview: PlanOverview) -> [PlanOverview.Button.Kind: Bool] {
        Dictionary(uniqueKeysWithValues: overview.buttons.map { ($0.kind, $0.enabled) })
    }

    /// No time of day in the headline or its reason: times are the rows' alone (ruling R1).
    private static func expectNoTimeOfDay(_ overview: PlanOverview, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = ([overview.headline] + [overview.reason].compactMap { $0 }).joined(separator: " ")
        #expect(text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil, sourceLocation: sourceLocation)
    }

    // MARK: Each state

    @Test func anIdlePlanIsUpToDateWithItsTimesInTheRows() {
        let overview = Self.overview(Self.status())
        #expect(overview.headline == "Up to date")
        #expect(overview.reason == nil)
        #expect(overview.severity == nil)
        #expect(overview.lastBackup == .init(value: "Today at 14:16", detail: nil))
        #expect(overview.nextBackup == .init(value: "Today at 15:16", detail: nil))
        #expect(Self.enabled(overview) == [.backUpNow: true, .restoreFiles: true])
        Self.expectNoTimeOfDay(overview)
    }

    /// Review R1 (b): the plan's off-Mac banner (no check-in URL) colours the menu's banner, never the plan's
    /// headline, which has nothing that needs attention.
    @Test func aPlanBannerDoesntColourTheHeadline() {
        let overview = Self.overview(Self.status(Self.plan(checkIn: false)))
        #expect(overview.headline == "Up to date")
        #expect(overview.severity == nil)
    }

    @Test func aRunningBackupShowsItsProgressAndCanBePaused() {
        let progress = BackupStatus(percentDone: 0.42, totalBytes: 1_000_000_000, bytesDone: 420_000_000)
        let plan = Self.status(phase: .running(progress, retrying: nil))
        let overview = Self.overview(plan)
        #expect(overview.headline == "Backing up — 42%")
        #expect(overview.reason == Self.menuLine(plan).detail)
        #expect(overview.progress == 0.42)
        #expect(overview.nextBackup == nil)
        #expect(Self.enabled(overview) == [.backUpNow: false, .pause: true, .restoreFiles: true])
    }

    @Test func aBackupWithNoProgressYetIsJustBackingUp() {
        #expect(Self.overview(Self.status(phase: .running(nil, retrying: nil))).headline == "Backing up")
    }

    @Test func aFailedBackupSaysWhyAndTheRowSaysWhen() {
        let plan = Self.status(failed: .wrongPassword, alerts: [.backupFailed])
        let overview = Self.overview(plan)
        #expect(overview.headline == "Backup failed")
        #expect(overview.reason == "wrong password")
        #expect(overview.reason == Self.menuLine(plan).detail)
        #expect(overview.severity == .error)
        #expect(overview.lastBackup == .init(value: "Today at 14:18", detail: "Failed"))
        Self.expectNoTimeOfDay(overview)
    }

    /// Review minor 3: the Last backup row follows an active `backupFailed` alert, as the headline does, even when the
    /// failed run has aged out of the records the status carries.
    @Test func anActiveFailureAlertWinsOverAnOlderSuccess() {
        let plan = Self.status(alerts: [.backupFailed], verdictKnown: false)
        let overview = Self.overview(plan)
        #expect(overview.headline == "Backup failed")
        #expect(overview.lastBackup == .init(value: "Not known", detail: "Failed"))
    }

    @Test func aPausedPlanSaysWhenItResumes() {
        let plan = Self.status(phase: .paused(until: Self.at(16, 0)))
        let overview = Self.overview(plan)
        #expect(overview.headline == "Paused")
        #expect(overview.isPaused)
        #expect(overview.reason == nil)
        #expect(overview.nextBackup == .init(value: "Today at 16:00", detail: "When the pause ends"))
        #expect(Self.enabled(overview) == [.backUpNow: true, .resume: true, .restoreFiles: true])
        Self.expectNoTimeOfDay(overview)
    }

    @Test func aStoppedPlanSaysWhy() {
        let overview = Self.overview(Self.status(phase: .stopped(reason: "The repository password is wrong")))
        #expect(overview.headline == "Stopped")
        #expect(overview.reason == "The repository password is wrong")
        #expect(overview.severity == .error)
        #expect(overview.nextBackup == nil)
        #expect(Self.enabled(overview) == [.backUpNow: true, .restoreFiles: true])
    }

    @Test func aPlanNeedingANewKitIsWaitingForIt() {
        let overview = Self.overview(Self.status(Self.plan(kit: false)))
        #expect(overview.headline == "Waiting for a new recovery kit")
        #expect(overview.severity == .warning)
        #expect(Self.enabled(overview) == [.backUpNow: false, .restoreFiles: true])
    }

    @Test func aPlanThatNeverRanSaysSo() {
        let overview = Self.overview(Self.status(backup: nil))
        #expect(overview.headline == "No backup yet")
        #expect(overview.lastBackup == .init(value: "None yet", detail: nil))
        #expect(overview.nextBackup == .init(value: "Today at 15:16", detail: nil))
    }

    @Test func aWarningNeedsAttentionWithTheMenusReason() {
        let plan = Self.status(backup: .warning(unreadable: 2))
        let overview = Self.overview(plan)
        #expect(overview.headline == "Needs attention")
        #expect(overview.reason == "2 files couldn't be read")
        #expect(overview.severity == .warning)
        #expect(overview.lastBackup == .init(value: "Today at 14:16", detail: nil))
    }

    @Test func aSkippedRunNeedsAttentionWithItsReason() {
        let plan = Self.status(phase: .skipped(.volumeNotMounted("Photos")))
        let overview = Self.overview(plan)
        #expect(overview.headline == "Needs attention")
        #expect(overview.reason == "Skipped: Photos isn't connected")
    }

    @Test func noRecentSuccessKeepsTheMenusWords() {
        let plan = Self.status(alerts: [.noRecentSuccess])
        let overview = Self.overview(plan)
        #expect(overview.headline == "No successful backup in 3 days")
        #expect(overview.headline == Self.menuLine(plan).status)
        #expect(overview.severity == .error)
    }

    @Test func rowsNameTheDay() {
        let plan = Self.status(backedUpAt: Self.at(9, 5, day: 14), next: Self.at(9, 0, day: 16))
        let overview = Self.overview(plan)
        #expect(overview.lastBackup?.value == "Yesterday at 09:05")
        #expect(overview.nextBackup?.value == "Tomorrow at 09:00")
        let older = Self.overview(Self.status(backedUpAt: Self.at(9, 5, day: 9), next: Self.at(9, 0, day: 18)))
        #expect(older.lastBackup?.value == "9 Nov at 09:05")
        #expect(older.nextBackup?.value == "18 Nov at 09:00")
    }

    /// Re-review N1: a plan with no backup yet whose first run was skipped says why, not just "Needs attention".
    @Test func aSkippedFirstRunSaysWhy() {
        let overview = Self.overview(Self.status(phase: .skipped(.onBattery), backup: nil))
        #expect(overview.headline == "Needs attention")
        #expect(overview.reason == SkipReason.onBattery.summary)
        #expect(overview.nextBackup == .init(value: "Today at 15:16", detail: nil))
    }

    /// Ruling R1 (b), exhaustively (re-review N1): over every phase, every combination of the alerts that colour a
    /// plan, a backup absent, good or with a warning, a failed run known or not, and every kit state, a coloured
    /// headline always comes with its reason or is the reason itself. Also with the agent unable to answer.
    @Test func aColouredHeadlineAlwaysSaysWhy() {
        let progress = BackupStatus(percentDone: 0.5, totalBytes: 100, bytesDone: 50)
        let phases: [PlanPhase] = [
            .idle, .running(nil, retrying: nil), .running(progress, retrying: "Can't reach it"),
            .paused(until: Self.at(16, 0)), .stopped(reason: "The repository password is wrong"),
            .skipped(.onBattery), .skipped(.agentUpdating), .skipped(.volumeNotMounted("Photos")),
        ]
        let colouring: [AlertCondition] = [
            .backupFailed, .noRecentSuccess, .checkInRejected, .checkFailed, .configurationError,
        ]
        let alertSets = (0..<(1 << colouring.count)).map { mask in
            colouring.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        }
        let backups: [RunOutcome?] = [nil, .success(snapshotID: "a"), .warning(unreadable: 3)]
        let failures: [RunOutcome?] = [nil, .wrongPassword]
        let kits = [true, false]
        let healths: [AgentHealthState] = [.healthy, .notRunning(reachable: true), .switchedOff]
        let selfExplaining: Set<String> = [
            "Backup failed", "Stopped", "Waiting for a new recovery kit", "No successful backup in 3 days",
            "The background agent isn't running", "The background agent is switched off",
        ]
        var checked = 0
        for phase in phases {
            for alerts in alertSets {
                for backup in backups {
                    for failure in failures {
                        for kit in kits {
                            for health in healths {
                                let state = Self.status(
                                    Self.plan(kit: kit), phase: phase, backup: backup, failed: failure, alerts: alerts)
                                let overview = Self.overview(state, health: health)
                                checked += 1
                                guard overview.severity != nil else { continue }
                                #expect(
                                    overview.reason != nil || selfExplaining.contains(overview.headline),
                                    "\(overview.headline) for \(phase), \(alerts), backup \(String(describing: backup)), kit \(kit), \(health)")
                                #expect(overview.headline.isEmpty == false)
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == phases.count * alertSets.count * backups.count * failures.count * kits.count * healths.count)
    }

    // MARK: The agent not answering, and the buttons

    @Test func anAgentThatIsntRunningDisablesEverything() {
        let overview = Self.overview(Self.status(), health: .notRunning(reachable: true))
        #expect(overview.headline == "The background agent isn't running")
        #expect(overview.reason == "No backups will happen.")
        #expect(Self.enabled(overview) == [.backUpNow: false, .restoreFiles: false])
    }

    /// Review minor 5: Pause and Resume follow the menu's enablement, not just the phase.
    @Test func pauseAndResumeAreDisabledWhenTheAgentCantBeAsked() {
        let running = Self.status(phase: .running(nil, retrying: nil))
        #expect(Self.enabled(Self.overview(running, health: .notRunning(reachable: true)))[.pause] == false)
        let paused = Self.status(phase: .paused(until: Self.at(16, 0)))
        #expect(Self.enabled(Self.overview(paused, health: .notRunning(reachable: true)))[.resume] == false)
    }

    @Test func aPausedPlanNeedingANewKitCantBeResumedHere() {
        let paused = Self.status(Self.plan(kit: false), phase: .paused(until: Self.at(16, 0)))
        #expect(Self.enabled(Self.overview(paused))[.resume] == false)
    }

    @Test func aPlanTheStatusDoesntListHasNoOverview() {
        let overview = MenuPresentation.overview(
            planID: UUID(), health: .healthy,
            status: AgentStatus(plans: [Self.status()], configError: nil, fdaMissing: false, generatedAt: Self.now),
            notificationsAuthorised: true, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(overview == nil)
    }

    /// The brief's order (Back Up Now first); the menu lists Resume first.
    @Test func theButtonsAreInTheBriefsOrderWithTheMenusTitles() {
        let paused = Self.overview(Self.status(phase: .paused(until: Self.at(16, 0))))
        #expect(paused.buttons.map(\.kind) == [.backUpNow, .resume, .restoreFiles])
        #expect(paused.buttons.map(\.title) == ["Back Up Now", "Resume", "Restore Files…"])
    }

    /// Final review I2: the Overview says a lasting failure to remove the chosen earlier snapshots, as information only.
    @Test func theOverviewSaysWhenTheChosenRemovalKeepsFailing() {
        var plan = Self.status()
        #expect(Self.overview(plan).earlierRemovalNote == nil)
        let quiet = Self.overview(plan)
        plan.earlierRemovalProblem = "Restorey couldn't count the earlier snapshots: Fatal: the preview broke."
        let shown = Self.overview(plan)
        #expect(shown.earlierRemovalNote == "Couldn't remove the earlier snapshots you chose: Restorey couldn't count the earlier snapshots: Fatal: the preview broke. Restorey will try again after the next backup.")
        // Information only: the headline, its colour and the reason are as without it.
        #expect(shown.headline == quiet.headline)
        #expect(shown.severity == quiet.severity)
        #expect(shown.reason == quiet.reason)
        #expect(MenuPresentation.make(
            health: .healthy,
            status: AgentStatus(plans: [plan], configError: nil, fdaMissing: false, generatedAt: Self.now),
            notificationsAuthorised: true, now: Self.now, calendar: Self.calendar, locale: Self.locale).icon == .ok)
    }
}
