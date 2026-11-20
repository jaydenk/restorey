import Foundation
import RestoreyCore

/// Registering, interrupting and cancelling runs, and the background runs `backUpNow` starts.
extension PlanRunner {
    // MARK: Interrupts and background runs

    /// Asks the plan's run in progress, if any, to stop. A request repeated while it is pending is
    /// ignored, and so is any request once one is pending: a Cancel after a pause leaves the run paused.
    /// `AgentState.pause` and `AgentState.cancel` are the ways in.
    /// Returns whether any run took the request (false: none in flight, or each already being stopped).
    @discardableResult
    func interrupt(planID: UUID, intent: InterruptIntent) async -> Bool {
        var accepted = false
        for handle in [handles[planID]].compactMap({ $0 }) + (measurementHandles[planID] ?? []) {
            let request = handle.requestStop(intent)
            accepted = accepted || request.accepted
            guard let process = request.process else { continue }
            await process.interrupt(intent, killAfter: deps.interruptGracePeriod)
        }
        return accepted
    }

    /// Cancel Backup: stops the plan's run and drops the backup Resume queued behind a run still stopping, so the
    /// user who pressed Cancel doesn't get a new backup when that run ends. A run a pause is already stopping
    /// stays paused (the first stop wins).
    /// Says what it did: it stopped a run or the queued backup; a pause was already stopping the run (so nothing was
    /// cancelled); or nothing was running.
    func cancel(planID: UUID) async -> CancelOutcome {
        let droppedQueued = startWhenPausedRunEnds.remove(planID) != nil
        let pausing = ([handles[planID]].compactMap { $0 } + (measurementHandles[planID] ?? [])).contains { $0.intent == .pause }
        let stopped = await interrupt(planID: planID, intent: .cancel)
        if stopped || droppedQueued { return .stoppedARun }
        return pausing ? .alreadyPausing : .nothingToCancel
    }

    /// Asks every run in flight (recovery's unlocks, backups, maintenance, create, adopt) to stop with
    /// `intent`, giving restic `killAfter` to honour SIGINT. A run whose step hasn't started yet stops
    /// before restic does. A run already being stopped (a pause) keeps that request, since a second
    /// SIGINT would make restic skip removing its lock and its outcome carries no verdict either, but its
    /// SIGKILL comes forward to `killAfter`: left at the pause's longer grace, a restic slow to honour
    /// SIGINT would outlive launchd's exit timeout and the next start would record a false failure.
    /// `AgentState.stopForSystem` is the way in.
    func interruptAll(_ intent: InterruptIntent, killAfter: Duration) async {
        for handle in Array(handles.values) + measurementHandles.values.flatMap({ $0 }) {
            if handle.intent == nil {
                guard let process = handle.request(intent) else { continue }
                await process.interrupt(intent, killAfter: killAfter)
            } else {
                await handle.process?.killIfStillRunning(after: killAfter)
            }
        }
    }

    /// Waits for the latest run `backUpNow` started for the plan and returns its record.
    func waitForBackgroundRun(planID: UUID) async -> RunRecord? {
        await background[planID]?.value
    }

    func startInBackground(_ planID: UUID) async throws {
        let handle = try await begin(planID, isBackup: true)
        background[planID] = Task {
            let record = await backup(planID: planID, trigger: .manual, handle: handle)
            await end(planID, handle)
            return record
        }
    }

    /// Waits for recovery, then registers the run with `AgentState` (which refuses while draining, for an
    /// unknown plan, a plan being deleted or already running) and gives it a handle `pause` can reach from
    /// that moment on.
    func begin(_ planID: UUID, isBackup: Bool = false) async throws -> RunHandle {
        await recovery?.value
        try await deps.state.requireRunnable(planID)
        if handles[planID] != nil {
            let name = (try? await deps.state.runInputs(planID).plan.name) ?? "This plan"
            throw AgentError.alreadyRunning(name: name)
        }
        let handle = RunHandle(isBackup: isBackup)
        handles[planID] = handle
        do {
            try await deps.state.beginRun(planID: planID)
        } catch {
            if handles[planID] === handle { handles[planID] = nil }
            throw error
        }
        return handle
    }

    func end(_ planID: UUID, _ handle: RunHandle) async {
        if handles[planID] === handle { handles[planID] = nil }
        await deps.state.endRun(planID: planID)
        guard startWhenPausedRunEnds.remove(planID) != nil else { return }
        // Paused again meanwhile: the new pause wins, and its end is the scheduler's catch-up.
        if let until = try? await deps.state.runInputs(planID).history.pausedUntil, until > deps.now() { return }
        do {
            try await startInBackground(planID)
        } catch {
            let message = (error as? AgentError)?.message ?? "\(error)"
            deps.agentLog("Couldn't start the backup Resume asked for, for plan \(planID.uuidString): \(message)")
        }
    }
}
