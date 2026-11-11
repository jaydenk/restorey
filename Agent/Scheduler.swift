import AgentCore
import Foundation
import RestoreyCore
import Synchronization

/// Runs `SchedulerCore` in the agent: a tick every minute on the continuous clock (which keeps counting
/// while the Mac sleeps, so the first tick after waking comes at once), and a nudge on wake, on the
/// network coming back, on a volume mounting and when a plan's settings change. Created early so the XPC service can nudge it; nudges
/// before `start` are dropped, since the first tick covers them.
final class Scheduler: Sendable {
    private let core = Mutex<SchedulerCore?>(nil)
    private let log: AppLog

    init(log: AppLog) {
        self.log = log
    }

    /// Starts ticking. Call once, after recovery has finished and the runner is attached, and never
    /// while draining.
    func start(runner: PlanRunner, observers: SystemObservers) {
        let log = log
        let core = SchedulerCore(
            clock: ContinuousClock(), now: { Date() }, runner: runner,
            waitForNetwork: { await observers.waitForNetwork() },
            log: { log.info($0) })
        self.core.withLock { $0 = core }
        Task { await core.run() }
        log.info("Scheduler started: checking every minute for plans that are due")
    }

    func nudge(_ reason: NudgeReason) {
        guard let core = core.withLock({ $0 }) else { return }
        Task { await core.nudge(reason: reason) }
    }
}
