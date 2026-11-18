import Foundation
import RestoreyCore

/// Every condition raised for a plan at `now`: what history decides (`activeConditions`), plus the two
/// the agent knows live.
///
/// - `notificationsOff`: the agent itself isn't authorised to post (`notificationsAuthorised` false, or
///   nil because the user hasn't been asked). The app's own permission doesn't cover the agent, and
///   posting without it reports success while nothing appears (docs/spike-findings.md, H3b).
/// - `fullDiskAccessMissing`: the runner raises it for a plan whose run found Full Disk Access missing
///   (`PlanRunner.commit`). It stands until a probe finds access granted (`fullDiskAccessMissing` false),
///   whichever plan ran it. Nil means no probe has answered since the agent started.
/// - `checkInRejected`: raised and cleared by the check-in results (`AgentState.checkInResult`); it
///   stands while it is in `activeAlerts` and the plan has a check-in URL.
public func alertConditions(
    history: PlanRunHistory, plan: Plan, now: Date, fullDiskAccessMissing: Bool?, notificationsAuthorised: Bool?
) -> Set<AlertCondition> {
    var conditions = activeConditions(history: history, plan: plan, now: now)
    if notificationsAuthorised != true { conditions.insert(.notificationsOff) }
    if fullDiskAccessAlertStands(history: history, fullDiskAccessMissing: fullDiskAccessMissing) {
        conditions.insert(.fullDiskAccessMissing)
    }
    if plan.hasCheckInURL, history.activeAlerts[.checkInRejected] != nil { conditions.insert(.checkInRejected) }
    return conditions
}

/// Whether a plan's `fullDiskAccessMissing` alert stands: a run raised it (`PlanRunner.commit`) and no probe
/// has found access granted since. `alertConditions` and the status's alerts both decide it here, so a
/// status built right after a probe that found access granted never shows the alert.
func fullDiskAccessAlertStands(history: PlanRunHistory, fullDiskAccessMissing: Bool?) -> Bool {
    history.activeAlerts[.fullDiskAccessMissing] != nil && fullDiskAccessMissing != false
}

/// One round of alert bookkeeping for a plan. A newly raised condition starts with no notification
/// sent; a cleared one is dropped, so raising it again notifies at once. `toNotify` is every raised
/// condition `shouldNotify` says is due, in a stable order, never `notificationsOff`: that one can't be
/// delivered as a notification, so it is shown in the app instead.
///
/// `next` doesn't count the notifications in `toNotify` as sent. The caller marks each one it delivers
/// (`markNotified(at:)`), so a post that fails is tried again on the next round.
public func reconcileAlerts(
    previous: [AlertCondition: AlertNotificationState], active: Set<AlertCondition>, now: Date
) -> (next: [AlertCondition: AlertNotificationState], toNotify: [AlertCondition]) {
    var next: [AlertCondition: AlertNotificationState] = [:]
    for condition in active {
        next[condition] = previous[condition] ?? AlertNotificationState(raisedAt: now, lastNotifiedAt: nil, count: 0)
    }
    let toNotify = AlertCondition.allCases.filter { condition in
        guard condition != .notificationsOff, let state = next[condition] else { return false }
        return shouldNotify(state, now: now)
    }
    return (next, toNotify)
}

extension AlertNotificationState {
    /// Records a notification delivered at `date`.
    public mutating func markNotified(at date: Date) {
        lastNotifiedAt = date
        count += 1
    }
}
