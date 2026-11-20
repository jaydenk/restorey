import Foundation
import RestoreyCore

/// Runs and measurements in flight, and restarting or re-registering once they end (Ruling R55).
extension AgentState {
    // MARK: Runs (the app's run actions are in AgentState+Runs.swift)

    func requireRunnable(_ id: UUID?) throws {
        try requireMutable()
        if let id { _ = try requirePlan(id) }
    }

    /// Registers an in-flight run. Refused while draining, in the config-error state, for an unknown
    /// plan, a plan being deleted, or a plan already running. Every successful call must be paired with
    /// `endRun`.
    public func beginRun(planID: UUID) throws {
        try requireRunnable(nil)
        let plan = try requirePlan(planID)
        guard !deleting.contains(planID) else { throw AgentError.planDeleting(name: plan.name) }
        guard running[planID] == nil else { throw AgentError.alreadyRunning(name: plan.name) }
        running[planID] = RunProgress()
        pushStatus()
    }

    /// What the scheduler decides from: `allRunInputs` without the plans that are running, read in one step, so a
    /// running plan (setup's first backup, confirmed and started together by `confirmKit`; a Back Up Now) is never
    /// offered to it as due.
    func scheduleInputs() -> [(plan: Plan, history: PlanRunHistory)] {
        allRunInputs().filter { running[$0.plan.id] == nil }
    }

    /// Records the latest progress and "retrying" line for a running plan. Pushed at most every
    /// `progressPushInterval`.
    public func updateRun(planID: UUID, progress: BackupStatus?, retrying: String?) {
        guard running[planID] != nil else { return }
        running[planID] = RunProgress(progress: progress, retrying: retrying)
        let now = now()
        if let last = lastProgressPush, now.timeIntervalSince(last) < Self.progressPushInterval, now >= last {
            return
        }
        lastProgressPush = now
        pushStatus(deliveringAlerts: false)
    }

    /// Registers a repository job that isn't a run of the plan (`PlanRunner`: the measurement after an adopt, as it
    /// reaches its turn in the queue, a credential check, recovery's unlock), so a drain and a delete wait for it while
    /// the plan's phase stays as it was. Refused while draining, in the config-error state, for an unknown plan or one
    /// being deleted.
    func beginMeasurement(planID: UUID) throws {
        try requireRunnable(planID)
        let plan = try requirePlan(planID)
        guard !deleting.contains(planID) else { throw AgentError.planDeleting(name: plan.name) }
        measuring[planID, default: 0] += 1
    }

    func isMeasuring(_ planID: UUID) -> Bool { measuring[planID] != nil }

    /// Ends one registration; the plan counts as measuring until the last ends.
    func endMeasurement(planID: UUID) {
        guard let count = measuring[planID] else { return }
        measuring[planID] = count > 1 ? count - 1 : nil
        guard count == 1 else { return }
        let waiters = measuringWaiters
        measuringWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        wakeDrainersIfIdle()
    }

    public func endRun(planID: UUID) {
        guard running.removeValue(forKey: planID) != nil else { return }
        pushStatus()
        wakeDrainersIfIdle()
    }

    /// Stops new runs and most writes, and returns once no run is in flight and no write is running or
    /// queued. There is deliberately no timeout for that: a long first backup is waited for (spec §8).
    /// Then it waits for the runner's queued check-in pings, for at most `pingBudget` (about the check-in
    /// sender's retry budget), so an exit doesn't drop a `/fail`. Draining is never undone; the agent exits
    /// afterwards.
    /// - Returns: false when the pings were given up on.
    @discardableResult
    public func prepareForRestart(pingBudget: Duration = drainPingBudget) async -> Bool {
        await drain(.restart, pingBudget: pingBudget)
    }

    /// The app's restart: `prepareForRestart`, then `reply` with its result, then the restart exit, once
    /// every restart drain asked for has been replied to. An agent that began a restart drain itself
    /// (`restartForReplacedBinary`) waits for this reply before exiting, so it is never lost.
    public func restart(pingBudget: Duration = drainPingBudget, reply: @Sendable (Bool) -> Void) async {
        restartRepliesOwed += 1
        let flushed = await prepareForRestart(pingBudget: pingBudget)
        reply(flushed)
        restartRepliesOwed -= 1
        exitWanted = true
        exitIfDone()
    }

    /// Called once at startup with where the refused run actions are logged (`agent.log`).
    public func attach(linkResolver: LinkResolver) {
        self.linkResolver = linkResolver
    }

    public func attach(agentLog: @escaping @Sendable (String) -> Void) {
        self.agentLog = agentLog
    }

    /// Called once at startup with how the agent exits for a restart and where it logs why.
    public func attach(restartExit: @escaping @Sendable () -> Void, log: @escaping @Sendable (String) -> Void) {
        self.restartExit = restartExit
        restartLog = log
    }

    /// The agent's executable on disk is no longer the one it was started from (an update replaced the
    /// bundle): drain for a restart on the agent's own initiative, then exit so launchd starts the new
    /// binary (Ruling R55). New runs are refused from now on; the restic step in flight finishes. Only
    /// the first call does anything.
    public func restartForReplacedBinary(pingBudget: Duration = drainPingBudget) {
        guard !replacementNoticed else { return }
        replacementNoticed = true
        if drainPurpose != .systemStop { drainPurpose = .restart }
        isDraining = true
        restartLog(
            "This agent's executable was replaced by an update: finishing the restic step in progress, then exiting so launchd starts the new one")
        Task {
            if !(await drain(.restart, pingBudget: pingBudget)) {
                restartLog(Self.pingsGivenUp(after: pingBudget))
            }
            exitWanted = true
            exitIfDone()
        }
    }

    /// How long a drain waits for the queued check-in pings: about the sender's retry budget (170 s).
    public static let drainPingBudget: Duration = .seconds(180)

    /// The log line when a drain stopped waiting for pings after `budget`.
    public static func pingsGivenUp(after budget: Duration) -> String {
        let seconds = Int(budget.components.seconds)
        let length = seconds % 60 == 0 && seconds >= 60
            ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")"
            : "\(seconds) second\(seconds == 1 ? "" : "s")"
        return "Gave up waiting for check-in pings after \(length); some may not have been sent"
    }

    private func exitIfDone() {
        // Once the system is stopping the agent, `stopForSystem` owns the exit and its deadline.
        guard exitWanted, restartRepliesOwed == 0, !exited, !isStoppingForSystem, let restartExit else { return }
        exited = true
        if replacementNoticed { restartLog("Exiting so launchd starts the agent's replaced executable") }
        restartExit()
    }

    /// The same drain, for the app's `unregister()` then `register()`: the agent stays up, drained and
    /// refusing every mutating call but `pause` and `cancel`, until `unregister()` stops it. Exiting instead would let
    /// launchd's `KeepAlive` start a fresh agent that `unregister()` could then kill mid-run.
    ///
    /// Refused with `restarting` while a restart drain is under way (the app's, or the agent's own for a
    /// replaced executable), also when one began during this wait: the agent will exit on its own, and the
    /// app's `unregister()` would then meet the fresh agent launchd starts, perhaps mid-backup.
    @discardableResult
    public func prepareForReregistration(pingBudget: Duration = drainPingBudget) async throws -> Bool {
        guard drainPurpose?.exitsAfterwards != true else { throw AgentError.restarting }
        let flushed = await drain(.reregistration, pingBudget: pingBudget)
        guard drainPurpose?.exitsAfterwards != true else { throw AgentError.restarting }
        return flushed
    }
}
