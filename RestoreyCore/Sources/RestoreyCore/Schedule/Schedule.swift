import Foundation

/// How long after a backup that failed on a repository lock before the next attempt.
private let lockedRetryInterval: TimeInterval = 15 * 60

/// When `plan` should next run, anacron-style. A pure function of its inputs: it never reads the
/// clock or the time zone, and intervals are elapsed seconds, so a time zone or daylight saving
/// change cannot move a run. The caller decides what `now` is.
///
/// - A plan that must not run returns `.distantFuture`: it has validation errors, a `stoppedReason`,
///   or no confirmed recovery kit.
/// - While `pausedUntil` is in the future, that is the answer. Once it has passed, the plan is due
///   at once (`now`), as a catch-up, however recently it last ran.
/// - When its newest backup record is `.skipped(.agentUpdating)`, the plan is due now: that backup never
///   ran, because the agent was being replaced (Ruling R55). Newer records of other operations (the next
///   agent's recovery unlock) don't change that.
/// - With no `lastAttemptAt`, the plan is due now.
/// - After a backup that ended `.locked` (the latest record in `recent`), the next run is
///   `lastAttemptAt` plus 15 minutes.
/// - Otherwise it is `lastAttemptAt` plus the interval. A run that was missed is `now`.
/// - If the clock went backwards (`lastAttemptAt` is after `now`), the delay is counted from `now`
///   instead, so the plan runs within one interval and not an interval after a time that has not
///   happened yet.
public func nextRunDate(plan: Plan, history: PlanRunHistory, now: Date) -> Date {
    if !plan.validationErrors().isEmpty || history.stoppedReason != nil || plan.recoveryKitConfirmedAt == nil {
        return .distantFuture
    }
    if let pausedUntil = history.pausedUntil {
        return pausedUntil > now ? pausedUntil : now
    }
    if history.recent.first(where: { $0.operation == .backup })?.outcome == .skipped(.agentUpdating) { return now }
    guard let lastAttemptAt = history.lastAttemptAt else { return now }

    let delay: TimeInterval
    if let latest = history.recent.first, case .backup = latest.operation, case .locked = latest.outcome {
        delay = lockedRetryInterval
    } else {
        switch plan.schedule {
        case .interval(let seconds): delay = TimeInterval(seconds)
        }
    }
    let reference = min(lastAttemptAt, now)
    return max(reference.addingTimeInterval(delay), now)
}
