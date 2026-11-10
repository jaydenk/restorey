import Foundation
import Testing

@testable import RestoreyCore

// Serialised because `timeZoneChangeDoesNotShift` swaps the process-wide default time zone.
@Suite(.serialized)
struct ScheduleTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 3600

    private func plan(
        interval: Int = 3600, confirmed: Bool = true, sources: [String] = ["/Users/me"]
    ) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Home",
            repository: .raw(repository: "/tmp/repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: sources, exclusions: [], now: Self.now)
        plan.schedule = .interval(seconds: interval)
        plan.recoveryKitConfirmedAt = confirmed ? Self.now : nil
        return plan
    }

    private func history(lastAttempt: Date?, latest: RunOutcome? = nil) -> PlanRunHistory {
        var history = PlanRunHistory()
        history.lastAttemptAt = lastAttempt
        if let latest, let lastAttempt {
            history.record(record(latest, at: lastAttempt))
        }
        return history
    }

    private func record(_ outcome: RunOutcome, at date: Date, operation: ResticOperation = .backup) -> RunRecord {
        RunRecord(
            id: UUID(), planID: UUID(), operation: operation, trigger: .scheduled,
            startedAt: date, endedAt: date, outcome: outcome, summary: nil, logFile: "l.log")
    }

    @Test func firstRunIsNow() {
        #expect(nextRunDate(plan: plan(), history: PlanRunHistory(), now: Self.now) == Self.now)
    }

    @Test func hourlyAfterAttempt() {
        let last = Self.now.addingTimeInterval(-600)
        #expect(nextRunDate(plan: plan(), history: history(lastAttempt: last), now: Self.now)
            == last.addingTimeInterval(Self.hour))
    }

    @Test func attemptCountsEvenWhenItFailed() {
        let last = Self.now.addingTimeInterval(-600)
        let failed = history(lastAttempt: last, latest: .failed(exitCode: 1, reason: "x"))
        #expect(nextRunDate(plan: plan(), history: failed, now: Self.now) == last.addingTimeInterval(Self.hour))
    }

    @Test func missedRunCatchesUpNow() {
        let last = Self.now.addingTimeInterval(-5 * Self.hour)
        #expect(nextRunDate(plan: plan(), history: history(lastAttempt: last), now: Self.now) == Self.now)
    }

    @Test func dueExactlyNowIsNow() {
        let last = Self.now.addingTimeInterval(-Self.hour)
        #expect(nextRunDate(plan: plan(), history: history(lastAttempt: last), now: Self.now) == Self.now)
    }

    @Test func pausedUntilWins() {
        var h = history(lastAttempt: Self.now.addingTimeInterval(-5 * Self.hour))
        let until = Self.now.addingTimeInterval(1800)
        h.pausedUntil = until
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == until)
    }

    @Test func pausedUntilBeatsFirstRun() {
        var h = PlanRunHistory()
        let until = Self.now.addingTimeInterval(1800)
        h.pausedUntil = until
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == until)
    }

    @Test func expiredPauseIsACatchUpRunNow() {
        // The interval has not elapsed, but the pause ending means the plan is due at once.
        var h = history(lastAttempt: Self.now.addingTimeInterval(-60))
        h.pausedUntil = Self.now.addingTimeInterval(-1)
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == Self.now)
    }

    @Test func lockedRetriesIn15Minutes() {
        let last = Self.now.addingTimeInterval(-300)
        let h = history(lastAttempt: last, latest: .locked)
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == last.addingTimeInterval(15 * 60))
    }

    @Test func lockedRetryInThePastRunsNow() {
        let last = Self.now.addingTimeInterval(-3 * Self.hour)
        let h = history(lastAttempt: last, latest: .locked)
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == Self.now)
    }

    @Test func lockedAppliesOnlyWhenTheLatestRecordIsALockedBackup() {
        let last = Self.now.addingTimeInterval(-300)
        // A locked check is not a locked backup.
        var other = history(lastAttempt: last)
        other.record(record(.locked, at: last, operation: .check))
        #expect(nextRunDate(plan: plan(), history: other, now: Self.now) == last.addingTimeInterval(Self.hour))
        // An older locked backup behind a newer success is history, not a retry.
        var recovered = PlanRunHistory()
        recovered.lastAttemptAt = last
        recovered.record(record(.locked, at: last.addingTimeInterval(-1000)))
        recovered.record(record(.success(snapshotID: "a"), at: last))
        #expect(nextRunDate(plan: plan(), history: recovered, now: Self.now) == last.addingTimeInterval(Self.hour))
    }

    @Test func pauseBeatsLockedRetry() {
        let last = Self.now.addingTimeInterval(-300)
        var h = history(lastAttempt: last, latest: .locked)
        let until = Self.now.addingTimeInterval(7200)
        h.pausedUntil = until
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == until)
    }

    @Test func stoppedPlanNeverRuns() {
        var h = PlanRunHistory()
        h.stoppedReason = "Wrong password"
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == .distantFuture)
        h.pausedUntil = Self.now.addingTimeInterval(60)
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == .distantFuture)
    }

    @Test func planWithoutRecoveryKitNeverRuns() {
        #expect(nextRunDate(plan: plan(confirmed: false), history: PlanRunHistory(), now: Self.now) == .distantFuture)
    }

    @Test func invalidPlanNeverRuns() {
        #expect(nextRunDate(plan: plan(sources: []), history: PlanRunHistory(), now: Self.now) == .distantFuture)
        #expect(nextRunDate(plan: plan(sources: ["relative"]), history: PlanRunHistory(), now: Self.now) == .distantFuture)
    }

    @Test func timeZoneChangeDoesNotShift() {
        // Intervals either side of both zones' daylight saving changes, as well as a plain one.
        let attempts = [
            Date(timeIntervalSince1970: 1_791_000_000),  // around Adelaide's 2026-10-04 change
            Date(timeIntervalSince1970: 1_793_400_000),  // around New York's 2026-11-01 change
            Self.now.addingTimeInterval(-600),
        ]
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        for last in attempts {
            var results: [Date] = []
            for identifier in ["Australia/Adelaide", "America/New_York"] {
                NSTimeZone.default = TimeZone(identifier: identifier)!
                results.append(nextRunDate(
                    plan: plan(interval: 86_400), history: history(lastAttempt: last),
                    now: last.addingTimeInterval(60)))
            }
            #expect(results[0] == results[1])
            // Exactly 24 hours of elapsed time, however long the local day was.
            #expect(results[0] == last.addingTimeInterval(86_400))
        }
    }

    @Test func clockJumpBackwardsStillRunsWithinOneInterval() {
        // The clock was set back a day: the last attempt now appears to be in the future.
        let last = Self.now.addingTimeInterval(24 * Self.hour)
        let next = nextRunDate(plan: plan(), history: history(lastAttempt: last), now: Self.now)
        #expect(next <= Self.now.addingTimeInterval(Self.hour))
        #expect(next >= Self.now)
    }

    @Test func clockJumpBackwardsClampsTheLockedRetryToo() {
        let last = Self.now.addingTimeInterval(24 * Self.hour)
        let next = nextRunDate(plan: plan(), history: history(lastAttempt: last, latest: .locked), now: Self.now)
        #expect(next <= Self.now.addingTimeInterval(15 * 60))
    }
}
