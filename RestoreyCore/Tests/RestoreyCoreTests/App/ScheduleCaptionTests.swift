import Foundation
import Testing
@testable import RestoreyCore

/// The line under the Schedule tab's interval control (Task 16a): the plan's last backup and next run, in the menu's
/// words and times, for the schedule as saved. Brisbane time, en-AU, now 14:20 on 15 November 2026.
struct ScheduleCaptionTests {
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

    private static func status(
        phase: PlanPhase = .idle, backedUpAt: Date? = at(14, 16), next: Date? = at(15, 16),
        setup: PlanSetupState = .complete
    ) -> PlanStatus {
        var plan = Plan.newHotPlan(
            name: "Local · repo", repository: .raw(repository: "/Users/me/restorey-test/repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        plan.setupCompletedAt = now
        plan.recoveryKitConfirmedAt = now
        let backup = backedUpAt.map {
            RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
                startedAt: $0.addingTimeInterval(-60), endedAt: $0, outcome: .success(snapshotID: "a"), summary: nil,
                logFile: "")
        }
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: backup, nextRunAt: next, alerts: [], lastBackup: backup,
            setupState: setup, latestBackupRecord: backup, latestBackupVerdict: backup)
    }

    private static func caption(_ status: PlanStatus, unsaved: Bool = false) -> String {
        MenuPresentation.scheduleCaption(
            status, hasUnsavedEdits: unsaved, now: now, calendar: calendar, locale: locale)
    }

    @Test func aBackedUpPlanSaysWhenItLastRanAndWhenNextIsDue() {
        #expect(Self.caption(Self.status()) == "Last backup at 14:16 · next at 15:16")
    }

    @Test func daysAreNamedAsTheMenuNamesThem() {
        let yesterday = Self.status(backedUpAt: Self.at(9, 5, day: 14), next: Self.at(9, 0, day: 16))
        #expect(Self.caption(yesterday) == "Last backup yesterday at 09:05 · next tomorrow at 09:00")
        let older = Self.status(backedUpAt: Self.at(9, 5, day: 9), next: Self.at(9, 0, day: 20))
        #expect(Self.caption(older) == "Last backup 9 Nov at 09:05 · next 20 Nov at 09:00")
    }

    @Test func aPlanWithNoBackupYetSaysWhenTheFirstIsDue() {
        #expect(Self.caption(Self.status(backedUpAt: nil)) == "No backup yet · first at 15:16")
    }

    @Test func aPausedPlanSaysWhenThePauseEnds() {
        let paused = Self.status(phase: .paused(until: Self.at(16, 0)))
        #expect(Self.caption(paused) == "Last backup at 14:16 · paused, resumes by itself at 16:00")
    }

    @Test func aRunningBackupHasNoNextTimeYet() {
        #expect(Self.caption(Self.status(phase: .running(nil, retrying: nil))) == "Last backup at 14:16 · backing up now")
    }

    @Test func aSkipIsNamedBesideTheNextRun() {
        let skipped = Self.status(phase: .skipped(.onBattery))
        #expect(Self.caption(skipped) == "Last backup at 14:16 · Skipped while on battery · next at 15:16")
        let drive = Self.status(phase: .skipped(.volumeNotMounted("Backup Drive")), backedUpAt: nil)
        #expect(Self.caption(drive) == "No backup yet · Skipped: Backup Drive isn't connected · first at 15:16")
        let wifi = Self.status(phase: .skipped(.skippedWiFi("Cafe")))
        #expect(Self.caption(wifi) == "Last backup at 14:16 · Skipped on Wi-Fi “Cafe” · next at 15:16")
    }

    /// The agent's own update is not a rule of the plan, and the menu doesn't treat it as a warning either.
    @Test func anUpdateSkipIsNotMentioned() {
        #expect(Self.caption(Self.status(phase: .skipped(.agentUpdating))) == "Last backup at 14:16 · next at 15:16")
    }

    @Test func aStoppedPlanHasNoNextRun() {
        let stopped = Self.status(phase: .stopped(reason: "Can't read settings"), next: nil)
        #expect(Self.caption(stopped) == "Last backup at 14:16 · stopped, so nothing is scheduled")
    }

    @Test func aPlanWaitingForAKitHasNoNextRun() {
        let waiting = Self.status(next: nil, setup: .needsNewKit)
        #expect(Self.caption(waiting) == "Last backup at 14:16 · waiting for a new recovery kit")
        let unfinished = Self.status(backedUpAt: nil, next: nil, setup: .unfinished)
        #expect(Self.caption(unfinished) == "No backup yet · setup isn't finished")
    }

    @Test func aCompletePlanWithNothingDueSaysSo() {
        #expect(Self.caption(Self.status(next: nil)) == "Last backup at 14:16 · no next run")
    }

    @Test func unsavedEditsKeepTheSavedScheduleAndSayTheNextTimeWillChange() {
        #expect(Self.caption(Self.status(), unsaved: true)
            == "Last backup at 14:16 · next at 15:16. Next run time updates when you save.")
        #expect(Self.caption(Self.status(backedUpAt: nil), unsaved: true)
            == "No backup yet · first at 15:16. Next run time updates when you save.")
    }
}
