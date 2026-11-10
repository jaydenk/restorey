import Foundation
import Testing

@testable import RestoreyCore

struct AlertPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400
    private static let hour: TimeInterval = 3_600

    private func plan(days: Int = 3, createdDaysAgo: Double = 30) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Home",
            repository: .raw(repository: "/tmp/repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [],
            now: Self.now.addingTimeInterval(-createdDaysAgo * Self.day))
        plan.noSuccessAlertDays = days
        return plan
    }

    private func record(
        _ outcome: RunOutcome, operation: ResticOperation = .backup, ago: TimeInterval = 0
    ) -> RunRecord {
        RunRecord(
            id: UUID(), planID: UUID(), operation: operation, trigger: .scheduled,
            startedAt: Self.now.addingTimeInterval(-ago), endedAt: Self.now.addingTimeInterval(-ago),
            outcome: outcome, summary: nil, logFile: "x.log")
    }

    private func history(successDaysAgo: Double?, recent: [RunRecord] = []) -> PlanRunHistory {
        var h = PlanRunHistory()
        h.lastSuccessAt = successDaysAgo.map { Self.now.addingTimeInterval(-$0 * Self.day) }
        h.recent = recent
        return h
    }

    @Test func noRecentSuccessAfterThreeDaysOfSkips() {
        let skips = (0..<5).map { record(.skipped(.onBattery), ago: Double($0) * Self.hour) }
        let h = history(successDaysAgo: 3 + 1.0 / 86_400, recent: skips)
        #expect(activeConditions(history: h, plan: plan(), now: Self.now) == [.noRecentSuccess])
    }

    @Test func noRecentSuccessNotRaisedAtTwoDays() {
        let h = history(successDaysAgo: 2)
        #expect(activeConditions(history: h, plan: plan(), now: Self.now).isEmpty)
    }

    @Test func noRecentSuccessNotRaisedAtExactlyThreshold() {
        let h = history(successDaysAgo: 3)
        #expect(activeConditions(history: h, plan: plan(), now: Self.now).isEmpty)
    }

    @Test func neverSucceededCountsFromPlanCreation() {
        let old = history(successDaysAgo: nil)
        #expect(activeConditions(history: old, plan: plan(createdDaysAgo: 4), now: Self.now) == [.noRecentSuccess])
        #expect(activeConditions(history: old, plan: plan(createdDaysAgo: 1), now: Self.now).isEmpty)
    }

    @Test func pausedRaisesNothing() {
        let recent = [record(.paused), record(.cancelled, ago: 60), record(.skipped(.noNetwork), ago: 120)]
        let h = history(successDaysAgo: 0.5, recent: recent)
        #expect(activeConditions(history: h, plan: plan(), now: Self.now).isEmpty)
    }

    @Test func configurationErrorFromStoppedReason() {
        var h = history(successDaysAgo: 0.5)
        h.stoppedReason = "The password is wrong."
        #expect(activeConditions(history: h, plan: plan(), now: Self.now) == [.configurationError])
    }

    @Test func backupFailedFromNewestBackupRecord() {
        let failed = history(
            successDaysAgo: 0.5, recent: [record(.failed(exitCode: 1, reason: "x")), record(.success(snapshotID: "a"), ago: 60)])
        #expect(activeConditions(history: failed, plan: plan(), now: Self.now) == [.backupFailed])

        let recovered = history(
            successDaysAgo: 0.5, recent: [record(.success(snapshotID: "a")), record(.failed(exitCode: 1, reason: "x"), ago: 60)])
        #expect(activeConditions(history: recovered, plan: plan(), now: Self.now).isEmpty)
    }

    @Test func interruptedBackupCountsAsFailed() {
        let h = history(successDaysAgo: 0.5, recent: [record(.interrupted)])
        #expect(activeConditions(history: h, plan: plan(), now: Self.now) == [.backupFailed])
    }

    @Test func backupFailedIgnoresNonBackupRecords() {
        // A newer successful check does not clear an older failed backup.
        let h = history(
            successDaysAgo: 0.5,
            recent: [record(.success(snapshotID: nil), operation: .check), record(.failed(exitCode: 1, reason: "x"), ago: 60)])
        #expect(activeConditions(history: h, plan: plan(), now: Self.now) == [.backupFailed])
    }

    @Test func checkFailedFromNewestCheckRecord() {
        let failed = history(
            successDaysAgo: 0.5,
            recent: [record(.failed(exitCode: 1, reason: "x"), operation: .check), record(.success(snapshotID: "a"), ago: 60)])
        #expect(activeConditions(history: failed, plan: plan(), now: Self.now) == [.checkFailed])

        let recovered = history(
            successDaysAgo: 0.5,
            recent: [record(.success(snapshotID: nil), operation: .check), record(.failed(exitCode: 1, reason: "x"), operation: .check, ago: 60)])
        #expect(activeConditions(history: recovered, plan: plan(), now: Self.now).isEmpty)
    }

    @Test func probeConditionsAreNeverComputedFromHistory() {
        var h = history(successDaysAgo: 10, recent: [record(.failed(exitCode: 1, reason: "x"))])
        h.stoppedReason = "stopped"
        let active = activeConditions(history: h, plan: plan(), now: Self.now)
        #expect(!active.contains(.fullDiskAccessMissing))
        #expect(!active.contains(.notificationsOff))
    }

    // MARK: verdicts

    private func backupState(_ outcomesNewestFirst: [RunOutcome], operation: ResticOperation = .backup) -> Set<AlertCondition> {
        let records = outcomesNewestFirst.enumerated().map { record($1, operation: operation, ago: Double($0) * 60) }
        return activeConditions(history: history(successDaysAgo: 0.5, recent: records), plan: plan(), now: Self.now)
    }

    @Test func failSkipFailStaysActiveThroughout() {
        let fail = RunOutcome.failed(exitCode: 1, reason: "x")
        #expect(backupState([fail]) == [.backupFailed])
        #expect(backupState([.skipped(.onBattery), fail]) == [.backupFailed])
        #expect(backupState([fail, .skipped(.onBattery), fail]) == [.backupFailed])
    }

    @Test func failThenNonVerdictsStaysActive() {
        let fail = RunOutcome.failed(exitCode: 1, reason: "x")
        for nonVerdict in [RunOutcome.paused, .cancelled, .locked, .skipped(.noNetwork)] {
            #expect(backupState([nonVerdict, fail]) == [.backupFailed])
        }
    }

    @Test func failThenVerdictSuccessClears() {
        let fail = RunOutcome.failed(exitCode: 1, reason: "x")
        for ok in [RunOutcome.success(snapshotID: "a"), .unchanged, .warning(unreadable: 1)] {
            #expect(backupState([ok, fail]).isEmpty)
        }
    }

    @Test func repositoryAndCredentialFailuresRaiseBackupFailed() {
        for outcome in [RunOutcome.wrongPassword, .repositoryMissing, .credentialsUnavailable] {
            #expect(backupState([outcome]) == [.backupFailed])
        }
    }

    @Test func checkFailureFollowedByLockedCheckStaysActive() {
        let fail = RunOutcome.failed(exitCode: 1, reason: "x")
        #expect(backupState([.locked, fail], operation: .check) == [.checkFailed])
        #expect(backupState([.interrupted], operation: .check) == [.checkFailed])
        #expect(backupState([.success(snapshotID: nil), fail], operation: .check).isEmpty)
    }

    /// `recent` keeps 50 records. A failure pushed out by skips, or by hourly backups for a weekly
    /// check, has not been cleared by anything, so a raised alert stays raised until a verdict clears it.
    @Test func raisedFailureOutlivesItsRecordLeavingRecent() {
        var h = history(successDaysAgo: 0, recent: (0..<50).map { _ in record(.skipped(.onBattery)) })
        #expect(activeConditions(history: h, plan: plan(), now: Self.now).isEmpty)
        let raised = AlertNotificationState(raisedAt: Self.now, lastNotifiedAt: nil, count: 0)
        h.activeAlerts[.backupFailed] = raised
        h.activeAlerts[.checkFailed] = raised
        #expect(activeConditions(history: h, plan: plan(), now: Self.now) == [.backupFailed, .checkFailed])

        h.recent.insert(record(.success(snapshotID: nil), operation: .check), at: 0)
        #expect(activeConditions(history: h, plan: plan(), now: Self.now) == [.backupFailed])
        h.recent.insert(record(.unchanged), at: 0)
        #expect(activeConditions(history: h, plan: plan(), now: Self.now).isEmpty)
    }

    @Test func clockGoingBackwardsIsDue() {
        let s = state(notifiedAt: 10 * Self.hour, count: 3)
        #expect(shouldNotify(s, now: Self.now))
    }

    // MARK: back-off

    private func state(notifiedAt: TimeInterval?, count: Int) -> AlertNotificationState {
        AlertNotificationState(
            raisedAt: Self.now, lastNotifiedAt: notifiedAt.map { Self.now.addingTimeInterval($0) }, count: count)
    }

    @Test func backOffSchedule() {
        var s = AlertNotificationState(raisedAt: Self.now, lastNotifiedAt: nil, count: 0)
        #expect(shouldNotify(s, now: Self.now))
        s.lastNotifiedAt = Self.now
        s.count = 1
        #expect(!shouldNotify(s, now: Self.now.addingTimeInterval(59 * 60)))
        #expect(!shouldNotify(s, now: Self.now.addingTimeInterval(Self.hour - 1)))

        // 1 h, then 6 h later (7 h), then 24 h later (31 h), then 24 h later (55 h).
        for (gap, expectedCount) in [(Self.hour, 2), (6 * Self.hour, 3), (24 * Self.hour, 4), (24 * Self.hour, 5)] {
            let last = s.lastNotifiedAt!
            #expect(!shouldNotify(s, now: last.addingTimeInterval(gap - 1)))
            #expect(shouldNotify(s, now: last.addingTimeInterval(gap)))
            s.lastNotifiedAt = last.addingTimeInterval(gap)
            s.count = expectedCount
        }
        #expect(s.lastNotifiedAt == Self.now.addingTimeInterval(55 * Self.hour))
    }

    @Test func backOffCapsAtDaily() {
        let s = state(notifiedAt: 0, count: 40)
        #expect(!shouldNotify(s, now: Self.now.addingTimeInterval(23 * Self.hour)))
        #expect(shouldNotify(s, now: Self.now.addingTimeInterval(24 * Self.hour)))
    }

    @Test func conditionClearedThenRaisedNotifiesAgainImmediately() {
        // The agent drops an alert's state when its condition clears, so the next raise starts at count 0.
        var alerts: [AlertCondition: AlertNotificationState] = [
            .backupFailed: state(notifiedAt: 0, count: 3)
        ]
        #expect(!shouldNotify(alerts[.backupFailed]!, now: Self.now.addingTimeInterval(Self.hour)))
        alerts[.backupFailed] = nil
        let raisedAgain = AlertNotificationState(
            raisedAt: Self.now.addingTimeInterval(Self.hour), lastNotifiedAt: nil, count: 0)
        #expect(shouldNotify(raisedAgain, now: Self.now.addingTimeInterval(Self.hour)))
    }

    @Test func nilLastNotifiedAlwaysNotifies() {
        #expect(shouldNotify(AlertNotificationState(raisedAt: Self.now, lastNotifiedAt: nil, count: 5), now: Self.now))
    }
}
