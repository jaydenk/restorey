import Foundation
import RestoreyCore

/// Recovery after the agent starts: interrupted records and left-behind locks.
extension PlanRunner {
    // MARK: Recovery

    func recover() async {
        // Lists of marked items left by an agent that died while restic ran: no restic of this plan is running now.
        try? FileManager.default.removeItem(at: deps.notForBackupDirectory)
        let entries = await deps.state.allRunInputs()
        let now = deps.now()
        var interrupted: Set<UUID> = []
        for (plan, history) in entries where history.runningRecordID != nil || history.runningRecord != nil {
            var record = history.runningRecord ?? RunRecord(
                id: history.runningRecordID ?? UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
                startedAt: history.lastAttemptAt ?? now, endedAt: now, outcome: .interrupted, summary: nil,
                logFile: "")
            record.endedAt = now
            record.outcome = .interrupted
            await commit(record, plan: plan)
            interrupted.insert(plan.id)
            // A "Backing up" the agent posted before it died goes (nothing, if none was posted or no notifier is attached).
            if record.operation == .backup { await deps.state.noteBackupEnded(plan, record: record) }
            if record.operation == .backup,
                let ping = pingAtEnd(outcome: .interrupted, logTail: [], redactor: redactor(for: plan))
            {
                queuePing(ping, planID: plan.id)
            }
        }

        var unlocked: Set<String> = []
        for (plan, _) in entries
        where plan.validationErrors().isEmpty && (plan.recoveryKitConfirmedAt != nil || interrupted.contains(plan.id)) {
            let key = RepositoryQueues.key(for: plan.repository)
            guard !unlocked.contains(key) else { continue }
            // Not a run of the plan (L168): registered like the measurement after an adopt, so a drain and the system
            // stop wait for it or reach it, but the plan isn't shown backing up. A pause or delete can't reach it: the
            // state gets the runner only after recovery, and refuses a delete meanwhile (`deletePlan`). Runs can't
            // start alongside it: they wait for recovery (`begin`). The handle is registered first, as `begin` does.
            let handle = RunHandle()
            measurementHandles[plan.id, default: []].append(handle)
            do {
                try await deps.state.beginMeasurement(planID: plan.id)
            } catch {
                measurementEnded(planID: plan.id, handle: handle)
                skippedUnlock(plan, reason: (error as? AgentError)?.message ?? "\(error)")
                continue
            }
            switch prepare(plan) {
            case .ready(let session):
                unlocked.insert(key)
                let step = await deps.queues.run(repository: key) { [self] () async -> StepResult? in
                    guard !(await isWindingDown()) else { return nil }
                    return await runStep(.unlock, trigger: .scheduled, session: session, handle: handle)
                }
                if let step {
                    await commit(step.record, plan: plan)
                } else {
                    skippedUnlock(plan, reason: AgentError.draining.message)
                }
            case .failed(_, let reason, _):
                skippedUnlock(plan, reason: reason)
            }
            // After its record is committed, so its plan is still there to record it.
            await deps.state.endMeasurement(planID: plan.id)
            measurementEnded(planID: plan.id, handle: handle)
        }
    }

    private func skippedUnlock(_ plan: Plan, reason: String) {
        deps.agentLog(
            "Recovery skipped the unlock for plan \(plan.id.uuidString), so a stale lock may remain until its next backup: \(reason)")
    }
}
