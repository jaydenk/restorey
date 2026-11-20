import Foundation
import RestoreyCore

/// Committing run records, alerts and check-in pings.
extension PlanRunner {
    // MARK: History and alerts

    /// Adds `record` to the plan's history with everything it implies, and refreshes the alerts. The
    /// in-progress marker is cleared only when it is this record's, so recovery's `.interrupted` record
    /// for an old run can never wipe the marker of a run that has started since.
    /// - Parameters:
    ///   - fda: the probe result this run saw, which raises or clears `fullDiskAccessMissing`.
    ///   - stoppedReason: set for a backup that stops the plan.
    func commit(
        _ record: RunRecord, plan: Plan, fda: FDAProbeResult? = nil, stoppedReason: String? = nil
    ) async {
        let now = deps.now()
        await write(plan.id) { history in
            if history.runningRecord?.id == record.id
                || (history.runningRecord == nil && history.runningRecordID == record.id)
            {
                history.runningRecordID = nil
                history.runningRecord = nil
            }
            history.record(record)
            let attemptBeforeRun = history.attemptBeforeRun
            Self.apply(record, stoppedReason: stoppedReason, to: &history)
            if record.operation == .backup, record.outcome == .cancelled {
                Self.keepSchedule(after: record, attemptBeforeRun: attemptBeforeRun, plan: plan, in: &history)
            }
            switch fda {
            case .missing?:
                if history.activeAlerts[.fullDiskAccessMissing] == nil {
                    history.activeAlerts[.fullDiskAccessMissing] = AlertNotificationState(
                        raisedAt: now, lastNotifiedAt: nil, count: 0)
                }
            case .granted?: history.activeAlerts[.fullDiskAccessMissing] = nil
            case .cannotVerify?, nil: break
            }
            Self.refreshAlerts(&history, plan: plan, now: now)
        }
    }

    func write(_ planID: UUID, _ change: @escaping @Sendable (inout PlanRunHistory) -> Void) async {
        do {
            try await deps.state.updateHistory(planID, change)
        } catch {
            // The run itself is unaffected, but its record is lost: say so where it can be found.
            let message = (error as? AgentError)?.message ?? "\(error)"
            logger.error("Couldn't save the run history: \(message, privacy: .public)")
            deps.agentLog("Couldn't save the run history for plan \(planID.uuidString): \(message)")
        }
    }

    func queuePing(_ ping: CheckInPing, planID: UUID) {
        let previous = pingTails[planID]
        let checkIn = deps.checkIn
        pingTails[planID] = Task {
            await previous?.value
            await checkIn.send(ping, planID: planID)
        }
    }
}
