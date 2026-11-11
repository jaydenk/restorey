import Foundation
import Testing

@testable import RestoreyCore

// Serialised only so `timeZoneChangeDoesNotShift`'s swap of the process-wide default time zone cannot
// overlap other tests in this suite; it does not guard against tests in other suites.
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

    @Test func lockedAppliesOnlyWhenTheNewestBackupRecordIsLocked() {
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

    /// Ruling R58: an agent that died mid-backup leaves an `.interrupted` record; the plan retries soon,
    /// 15 minutes after the attempt, even once the next agent's recovery unlock is the newest record.
    @Test func interruptedRetriesIn15Minutes() {
        let last = Self.now.addingTimeInterval(-300)
        var h = history(lastAttempt: last, latest: .interrupted)
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == last.addingTimeInterval(15 * 60))
        h.record(record(.success(snapshotID: nil), at: Self.now, operation: .unlock))
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == last.addingTimeInterval(15 * 60))
        // Not now, and not a tight loop: an interruption long ago is a catch-up, not a burst.
        let old = history(lastAttempt: Self.now.addingTimeInterval(-3 * Self.hour), latest: .interrupted)
        #expect(nextRunDate(plan: plan(), history: old, now: Self.now) == Self.now)
    }

    /// A later successful backup puts the plan back on its interval.
    @Test func aSuccessAfterAnInterruptionUsesTheNormalInterval() {
        let last = Self.now.addingTimeInterval(-300)
        var h = PlanRunHistory()
        h.record(record(.interrupted, at: last.addingTimeInterval(-900)))
        h.record(record(.success(snapshotID: "a"), at: last))
        h.lastAttemptAt = last
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == last.addingTimeInterval(Self.hour))
    }

    /// An interrupted check (the agent died during maintenance) is not an interrupted backup.
    @Test func anInterruptedCheckIsNotAShortRetry() {
        let last = Self.now.addingTimeInterval(-300)
        var h = history(lastAttempt: last, latest: .success(snapshotID: "a"))
        h.record(record(.interrupted, at: last, operation: .check))
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == last.addingTimeInterval(Self.hour))
    }

    /// A backup skipped because the agent was being replaced never happened: the next agent runs it at
    /// once, even after its recovery's unlock has become the newest record (Ruling R55).
    @Test func aBackupSkippedForAnUpdateIsDueAtOnce() {
        let last = Self.now.addingTimeInterval(-60)
        var h = history(lastAttempt: last, latest: .skipped(.agentUpdating))
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == Self.now)
        h.record(record(.success(snapshotID: nil), at: Self.now, operation: .unlock))
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == Self.now)
        // Other skips still wait for the interval, and a pause still wins.
        let battery = history(lastAttempt: last, latest: .skipped(.onBattery))
        #expect(nextRunDate(plan: plan(), history: battery, now: Self.now) == last.addingTimeInterval(Self.hour))
        let until = Self.now.addingTimeInterval(600)
        h.pausedUntil = until
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == until)
        // A newer backup supersedes it.
        h.pausedUntil = nil
        h.record(record(.success(snapshotID: "a"), at: last))
        h.lastAttemptAt = last
        #expect(nextRunDate(plan: plan(), history: h, now: Self.now) == last.addingTimeInterval(Self.hour))
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

    @Test func zeroIntervalPlanNeverRuns() {
        #expect(nextRunDate(plan: plan(interval: 0), history: PlanRunHistory(), now: Self.now) == .distantFuture)
    }
}
