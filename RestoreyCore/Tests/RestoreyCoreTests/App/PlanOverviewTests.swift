import Foundation
import Testing
@testable import RestoreyCore

/// A plan's Overview tab in Settings (Task 14c, owner 15 Nov 2026): the menu's line for the plan, its last and next
/// backup, and Back Up Now, Pause, Resume and Restore Files… enabled as the menu's items are. Brisbane time, en-AU.
struct PlanOverviewTests {
    private static let locale = Locale(identifier: "en_AU")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        calendar.locale = locale
        return calendar
    }()

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: hour, minute: minute))!
    }

    private static let now = at(14, 20)

    private static func plan(setup: Bool = true, kit: Bool = true) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Local · repo", repository: .raw(repository: "/Users/me/restorey-test/repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        plan.hasCheckInURL = true
        plan.setupCompletedAt = setup ? now : nil
        plan.recoveryKitConfirmedAt = kit && setup ? now : nil
        return plan
    }

    private static func record(_ plan: Plan, _ outcome: RunOutcome, at end: Date) -> RunRecord {
        RunRecord(
            id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
            startedAt: end.addingTimeInterval(-60), endedAt: end, outcome: outcome, summary: nil, logFile: "")
    }

    private static func status(
        _ plan: Plan = plan(), phase: PlanPhase = .idle, backup: RunOutcome? = .success(snapshotID: "a"),
        failed: RunOutcome? = nil, next: Date? = at(15, 16), alerts: [AlertCondition] = []
    ) -> PlanStatus {
        let good = backup.map { record(plan, $0, at: at(14, 16)) }
        let bad = failed.map { record(plan, $0, at: at(14, 18)) }
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: bad ?? good, nextRunAt: next, alerts: alerts, lastBackup: good,
            latestBackupRecord: bad ?? good, latestBackupVerdict: bad ?? good)
    }

    private static func overview(_ plan: PlanStatus, health: AgentHealthState = .healthy) -> PlanOverview {
        MenuPresentation.overview(
            planID: plan.plan.id, health: health,
            status: AgentStatus(plans: [plan], configError: nil, fdaMissing: false, generatedAt: now),
            notificationsAuthorised: true, rates: [:], now: now, calendar: calendar, locale: locale)!
    }

    private static func menuLine(_ plan: PlanStatus) -> PlanLine {
        MenuPresentation.planLine(for: plan, bytesPerSecond: nil, now: now, calendar: calendar, locale: locale)
    }

    private static func enabled(_ overview: PlanOverview) -> [PlanOverview.Button.Kind: Bool] {
        Dictionary(uniqueKeysWithValues: overview.buttons.map { ($0.kind, $0.enabled) })
    }

    // MARK: Each state, in the menu's words

    @Test func anIdlePlanSaysWhenItLastAndNextBacksUp() {
        let plan = Self.status()
        let overview = Self.overview(plan)
        #expect(overview.status == Self.menuLine(plan).status)
        #expect(overview.status == "Backed up at 14:16")
        #expect(overview.lastBackup == "Backed up at 14:16")
        #expect(overview.nextBackup == "Next 15:16")
        #expect(Self.enabled(overview) == [.backUpNow: true, .restoreFiles: true])
    }

    @Test func aRunningBackupShowsItsProgressAndCanBePaused() {
        let progress = BackupStatus(percentDone: 0.42, totalBytes: 1_000_000_000, bytesDone: 420_000_000)
        let plan = Self.status(phase: .running(progress, retrying: nil))
        let overview = Self.overview(plan)
        let line = Self.menuLine(plan)
        #expect(overview.status == "Backing up")
        #expect(overview.statusDetail == line.detail)
        #expect(overview.progress == 0.42)
        #expect(overview.nextBackup == nil)
        #expect(Self.enabled(overview) == [.backUpNow: false, .pause: true, .restoreFiles: true])
    }

    @Test func aFailedBackupSaysWhenAndWhy() {
        let plan = Self.status(failed: .wrongPassword, alerts: [.backupFailed])
        let overview = Self.overview(plan)
        #expect(overview.status == Self.menuLine(plan).status)
        #expect(overview.status == "Backup failed at 14:18")
        #expect(overview.statusDetail == "wrong password")
        #expect(overview.severity == .error)
        #expect(overview.lastBackup == "Backup failed at 14:18")
        #expect(overview.lastBackupDetail == "wrong password")
    }

    @Test func aPausedPlanSaysWhenItResumesAndCanBeResumed() {
        let plan = Self.status(phase: .paused(until: Self.at(16, 0)))
        let overview = Self.overview(plan)
        #expect(overview.status == "Paused")
        #expect(overview.isPaused)
        #expect(overview.nextBackup == "Resumes by itself at 16:00")
        #expect(overview.nextBackup == Self.menuLine(plan).detail)
        #expect(Self.enabled(overview) == [.backUpNow: true, .resume: true, .restoreFiles: true])
    }

    @Test func aStoppedPlanSaysWhy() {
        let plan = Self.status(phase: .stopped(reason: "The repository password is wrong"))
        let overview = Self.overview(plan)
        #expect(overview.status == "Stopped")
        #expect(overview.statusDetail == "The repository password is wrong")
        #expect(overview.nextBackup == nil)
        #expect(Self.enabled(overview) == [.backUpNow: true, .restoreFiles: true])
    }

    @Test func aPlanNeedingANewKitCantBackUpOrPause() {
        let plan = Self.status(Self.plan(kit: false))
        let overview = Self.overview(plan)
        #expect(overview.status == Self.menuLine(plan).status)
        #expect(Self.enabled(overview) == [.backUpNow: false, .restoreFiles: true])
    }

    @Test func aPlanThatNeverRanSaysSo() {
        let plan = Self.status(backup: nil)
        let overview = Self.overview(plan)
        #expect(overview.status == "No backup yet")
        #expect(overview.lastBackup == "No backup yet")
        #expect(overview.nextBackup == "Next 15:16")
    }

    @Test func aWarningSaysHowManyFilesCouldntBeRead() {
        let plan = Self.status(backup: .warning(unreadable: 2))
        let overview = Self.overview(plan)
        #expect(overview.lastBackup == "Backed up at 14:16")
        #expect(overview.lastBackupDetail == "2 files couldn't be read")
    }

    /// The agent not answering: nothing can be asked of it, as in the menu, and the status says why.
    @Test func anAgentThatIsntRunningDisablesEverything() {
        let plan = Self.status()
        let overview = Self.overview(plan, health: .notRunning(reachable: true))
        #expect(overview.status == "The background agent isn't running")
        #expect(Self.enabled(overview) == [.backUpNow: false, .restoreFiles: false])
    }

    @Test func aPlanTheStatusDoesntListHasNoOverview() {
        let overview = MenuPresentation.overview(
            planID: UUID(), health: .healthy,
            status: AgentStatus(plans: [Self.status()], configError: nil, fdaMissing: false, generatedAt: Self.now),
            notificationsAuthorised: true, rates: [:], now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(overview == nil)
    }

    @Test func theButtonsAreInTheMenusOrder() {
        let paused = Self.overview(Self.status(phase: .paused(until: Self.at(16, 0))))
        #expect(paused.buttons.map(\.kind) == [.backUpNow, .resume, .restoreFiles])
        #expect(paused.buttons.map(\.title) == ["Back Up Now", "Resume", "Restore Files…"])
    }
}
