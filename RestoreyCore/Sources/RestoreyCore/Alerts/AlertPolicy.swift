import Foundation

/// The conditions that history alone can raise, for one plan at `now`.
///
/// - `noRecentSuccess`: the last success (or the plan's creation, if it has never succeeded) is more
///   than `plan.noSuccessAlertDays` days old. Skips, pauses and cancellations never reset it, so a
///   machine that is always on battery still ends up telling the user.
/// - `backupFailed`: the newest backup record failed or was interrupted. An interrupted run counts as
///   failed because the agent died or was killed before the backup finished.
/// - `checkFailed`: the newest check record failed.
/// - `configurationError`: the plan has been stopped (`stoppedReason`), for example after a wrong password.
///
/// `fullDiskAccessMissing` and `notificationsOff` are not computed here. The agent raises them from live
/// probes (Tasks 14 and 16), because history cannot know them.
public func activeConditions(history: PlanRunHistory, plan: Plan, now: Date) -> Set<AlertCondition> {
    var conditions: Set<AlertCondition> = []

    let reference = history.lastSuccessAt ?? plan.createdAt
    if now.timeIntervalSince(reference) > TimeInterval(plan.noSuccessAlertDays) * 86_400 {
        conditions.insert(.noRecentSuccess)
    }

    // `recent` is newest first.
    if let backup = history.recent.first(where: { $0.operation == .backup }) {
        switch backup.outcome {
        case .failed, .interrupted: conditions.insert(.backupFailed)
        default: break
        }
    }
    if let check = history.recent.first(where: { $0.operation == .check }) {
        if case .failed = check.outcome { conditions.insert(.checkFailed) }
    }

    if history.stoppedReason != nil { conditions.insert(.configurationError) }
    return conditions
}

/// Whether to send a notification for a raised alert now. Timings are measured from the previous
/// notification: at once (nothing sent yet), then after 1 h, then 6 h, then every 24 h.
/// The agent clears an alert's state when its condition clears, so a re-raise starts again at once.
public func shouldNotify(_ state: AlertNotificationState, now: Date) -> Bool {
    guard let last = state.lastNotifiedAt, state.count > 0 else { return true }
    let gap: TimeInterval =
        switch state.count {
        case 1: 3_600
        case 2: 6 * 3_600
        default: 24 * 3_600
        }
    return now.timeIntervalSince(last) >= gap
}
