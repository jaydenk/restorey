import Foundation

/// The conditions that history alone can raise, for one plan at `now`.
///
/// - `noRecentSuccess`: the last success (or the plan's creation, if it has never succeeded) is more
///   than `plan.noSuccessAlertDays` days old. Skips, pauses and cancellations never reset it, so a
///   machine that is always on battery still ends up telling the user.
/// - `backupFailed`: the newest backup record with a verdict is a failure: `failed`, `interrupted` (the
///   agent died mid-run), `wrongPassword`, `repositoryMissing` or `credentialsUnavailable`.
///   `success`, `unchanged` and `warning` clear it; `paused`, `cancelled`, `skipped` and `locked`
///   carry no verdict and are looked past.
/// - `checkFailed`: the same rule applied to the newest check record.
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

    // `recent` is newest first. Only a record with a verdict can raise or clear an alert: a pause, a
    // cancellation, a skip or a lock says nothing about whether the last real attempt worked.
    if let backup = history.recent.first(where: { $0.operation == .backup && $0.outcome.isVerdict }),
        backup.outcome.isFailureVerdict
    {
        conditions.insert(.backupFailed)
    }
    if let check = history.recent.first(where: { $0.operation == .check && $0.outcome.isVerdict }),
        check.outcome.isFailureVerdict
    {
        conditions.insert(.checkFailed)
    }

    if history.stoppedReason != nil { conditions.insert(.configurationError) }
    return conditions
}

/// Whether to send a notification for a raised alert now. Timings are measured from the previous
/// notification: at once (nothing sent yet), then after 1 h, then 6 h, then every 24 h.
/// The agent clears an alert's state when its condition clears, so a re-raise starts again at once.
public func shouldNotify(_ state: AlertNotificationState, now: Date) -> Bool {
    guard let last = state.lastNotifiedAt, state.count > 0 else { return true }
    // The clock went backwards: waiting out the gap could take arbitrarily long, so treat it as due.
    if now < last { return true }
    let gap: TimeInterval =
        switch state.count {
        case 1: 3_600
        case 2: 6 * 3_600
        default: 24 * 3_600
        }
    return now.timeIntervalSince(last) >= gap
}

extension RunOutcome {
    /// False for outcomes that say nothing about whether the work succeeded.
    fileprivate var isVerdict: Bool {
        switch self {
        case .paused, .cancelled, .skipped, .locked: false
        default: true
        }
    }

    fileprivate var isFailureVerdict: Bool {
        switch self {
        case .failed, .interrupted, .wrongPassword, .repositoryMissing, .credentialsUnavailable: true
        default: false
        }
    }
}
