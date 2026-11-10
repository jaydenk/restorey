import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

struct AlertReconciliationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    /// One round as the agent runs it: reconcile, then mark every condition to notify as delivered.
    private func round(
        _ previous: [AlertCondition: AlertNotificationState], active: Set<AlertCondition>, at offset: TimeInterval
    ) -> (next: [AlertCondition: AlertNotificationState], notified: [AlertCondition]) {
        let now = start.addingTimeInterval(offset)
        var (next, toNotify) = reconcileAlerts(previous: previous, active: active, now: now)
        for condition in toNotify { next[condition]?.markNotified(at: now) }
        return (next, toNotify)
    }

    @Test func aNewConditionIsRaisedWithFreshState() {
        let (next, toNotify) = reconcileAlerts(previous: [:], active: [.backupFailed], now: start)
        #expect(next == [.backupFailed: AlertNotificationState(raisedAt: start, lastNotifiedAt: nil, count: 0)])
        #expect(toNotify == [.backupFailed])
    }

    @Test func notifiesAtOnceThenBacksOff() {
        var alerts: [AlertCondition: AlertNotificationState] = [:]
        var notified: [AlertCondition]

        (alerts, notified) = round(alerts, active: [.backupFailed], at: 0)
        #expect(notified == [.backupFailed])
        #expect(alerts[.backupFailed] == AlertNotificationState(raisedAt: start, lastNotifiedAt: start, count: 1))

        (alerts, notified) = round(alerts, active: [.backupFailed], at: 59 * 60)
        #expect(notified.isEmpty)
        (alerts, notified) = round(alerts, active: [.backupFailed], at: hour)
        #expect(notified == [.backupFailed])

        // 6 h after the second notification.
        (alerts, notified) = round(alerts, active: [.backupFailed], at: hour + 6 * hour - 1)
        #expect(notified.isEmpty)
        (alerts, notified) = round(alerts, active: [.backupFailed], at: hour + 6 * hour)
        #expect(notified == [.backupFailed])

        // Then every 24 h.
        let third = hour + 6 * hour
        (alerts, notified) = round(alerts, active: [.backupFailed], at: third + 24 * hour - 1)
        #expect(notified.isEmpty)
        (alerts, notified) = round(alerts, active: [.backupFailed], at: third + 24 * hour)
        #expect(notified == [.backupFailed])
        (alerts, notified) = round(alerts, active: [.backupFailed], at: third + 48 * hour)
        #expect(notified == [.backupFailed])
        #expect(alerts[.backupFailed]?.count == 5)
        #expect(alerts[.backupFailed]?.raisedAt == start)
    }

    @Test func aClearedConditionIsRemoved() {
        let (raised, _) = round([:], active: [.backupFailed, .noRecentSuccess], at: 0)
        let (next, toNotify) = reconcileAlerts(previous: raised, active: [.noRecentSuccess], now: start.addingTimeInterval(60))
        #expect(next.keys.sorted { $0.rawValue < $1.rawValue } == [.noRecentSuccess])
        #expect(toNotify.isEmpty)
    }

    @Test func aConditionRaisedAgainAfterClearingNotifiesAtOnce() {
        var (alerts, _) = round([:], active: [.checkFailed], at: 0)
        (alerts, _) = round(alerts, active: [], at: 60)
        #expect(alerts.isEmpty)
        let notified: [AlertCondition]
        (alerts, notified) = round(alerts, active: [.checkFailed], at: 120)
        #expect(notified == [.checkFailed])
        #expect(alerts[.checkFailed] == AlertNotificationState(
            raisedAt: start.addingTimeInterval(120), lastNotifiedAt: start.addingTimeInterval(120), count: 1))
    }

    /// A post that failed isn't marked, so the next round tries again rather than waiting an hour.
    @Test func anUndeliveredNotificationIsTriedAgain() {
        let (unmarked, first) = reconcileAlerts(previous: [:], active: [.backupFailed], now: start)
        #expect(first == [.backupFailed])
        let (_, second) = reconcileAlerts(previous: unmarked, active: [.backupFailed], now: start.addingTimeInterval(60))
        #expect(second == [.backupFailed])
    }

    @Test func notificationsOffIsRaisedButNeverNotified() {
        var alerts: [AlertCondition: AlertNotificationState] = [:]
        for offset in [0, hour, 7 * hour, 31 * hour, 55 * hour] {
            let (next, toNotify) = reconcileAlerts(
                previous: alerts, active: [.notificationsOff, .backupFailed], now: start.addingTimeInterval(offset))
            #expect(!toNotify.contains(.notificationsOff))
            #expect(next[.notificationsOff] != nil)
            alerts = next
        }
        #expect(alerts[.notificationsOff] == AlertNotificationState(raisedAt: start, lastNotifiedAt: nil, count: 0))
    }

    @Test func severalConditionsAreNotifiedInAStableOrder() {
        let (_, toNotify) = reconcileAlerts(
            previous: [:], active: [.noRecentSuccess, .backupFailed, .fullDiskAccessMissing, .checkFailed], now: start)
        #expect(toNotify == [.backupFailed, .checkFailed, .fullDiskAccessMissing, .noRecentSuccess])
    }

    // MARK: Live conditions

    private func plan() -> Plan {
        Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []), origin: .created, hostLabel: "mac",
            sources: ["/Users/me/Documents"], exclusions: [], now: start)
    }

    @Test func notificationsOffWhenTheAgentIsNotAuthorised() {
        var history = PlanRunHistory()
        history.lastSuccessAt = start
        for authorised: Bool? in [false, nil] {
            let conditions = alertConditions(
                history: history, plan: plan(), now: start, fullDiskAccessMissing: nil, notificationsAuthorised: authorised)
            #expect(conditions == [.notificationsOff])
        }
        #expect(alertConditions(
            history: history, plan: plan(), now: start, fullDiskAccessMissing: nil, notificationsAuthorised: true
        ).isEmpty)
    }

    /// The runner raises Full Disk Access per plan; the latest probe clears it once it is granted.
    @Test func fullDiskAccessComesFromTheRunnerAndClearsWhenGranted() {
        var history = PlanRunHistory()
        history.lastSuccessAt = start
        history.activeAlerts[.fullDiskAccessMissing] = AlertNotificationState(raisedAt: start, lastNotifiedAt: nil, count: 0)
        func conditions(_ probe: Bool?, _ history: PlanRunHistory) -> Set<AlertCondition> {
            alertConditions(history: history, plan: plan(), now: start, fullDiskAccessMissing: probe, notificationsAuthorised: true)
        }
        #expect(conditions(true, history) == [.fullDiskAccessMissing])
        // Not probed since the agent started: what the runner recorded stands.
        #expect(conditions(nil, history) == [.fullDiskAccessMissing])
        #expect(conditions(false, history).isEmpty)
        // A plan that hasn't run since the probe found it missing isn't raised until it runs.
        #expect(conditions(true, PlanRunHistory()).subtracting([.noRecentSuccess]).isEmpty)
    }

    @Test func historyConditionsAreIncluded() {
        var history = PlanRunHistory()
        history.lastSuccessAt = start
        history.stoppedReason = "The repository password is wrong"
        let conditions = alertConditions(
            history: history, plan: plan(), now: start.addingTimeInterval(4 * 86_400), fullDiskAccessMissing: false,
            notificationsAuthorised: true)
        #expect(conditions == [.configurationError, .noRecentSuccess])
    }
}
