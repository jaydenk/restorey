import Foundation

/// How long after a backup that ended `.locked`, `.interrupted` or `.stoppedBySystem` before the next attempt. Short, because
/// the backup didn't finish and should be tried again soon; not zero, so something that kills the agent on
/// every run (Ruling R58) or a lock that another client holds doesn't become a tight loop.
private let shortRetryInterval: TimeInterval = 15 * 60

/// True when the plan's newest backup record ended `.locked`, `.interrupted` or `.stoppedBySystem`: the
/// backup didn't finish and is retried after `shortRetryInterval` rather than the plan's interval
/// (Rulings R58, R63, R67). Newer
/// records of other operations (the next agent's recovery unlock) don't change that. The one definition
/// of a short retry: `nextRunDate` times it and the scheduler labels it `.retry`.
public func isShortRetry(_ history: PlanRunHistory) -> Bool {
    switch history.recent.first(where: { $0.operation == .backup })?.outcome {
    case .locked?, .interrupted?, .stoppedBySystem?: true
    default: false
    }
}

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
/// - When its newest backup record ended `.locked`, `.interrupted` (the agent died mid-run, Ruling R58) or
///   `.stoppedBySystem` (logout or shutdown stopped it, Ruling R67),
///   the next run is `lastAttemptAt` plus 15 minutes (`isShortRetry`).
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
    if isShortRetry(history) {
        delay = shortRetryInterval
    } else {
        switch plan.schedule {
        case .interval(let seconds): delay = TimeInterval(seconds)
        }
    }
    let reference = min(lastAttemptAt, now)
    return max(reference.addingTimeInterval(delay), now)
}
