import Foundation
import RestoreyCore

/// Setup step "Done" (UI design §4 step 7).
extension SetupModel {
    var firstBackup: FirstBackupProgress? {
        guard let firstBackupBaseline else { return nil }
        return FirstBackupProgress.make(
            plan: planStatus, baseline: firstBackupBaseline, bytesPerSecond: bytesPerSecond, now: Date(),
            calendar: .current, locale: .current)
    }

    /// "Start first backup": saves anything not yet saved, confirms the recovery kit (deferred from its step
    /// so the plan couldn't run mid-setup, `SetupFlow`), then starts the backup. The plan is complete from
    /// the confirmation on, so the saved progress goes: there is nothing left to resume. Confirming makes the
    /// plan due, so the scheduler may start it before Back Up Now arrives; the agent then answers "already
    /// running" (`BackUpNowReply.alreadyRunning`) rather than refusing, and either way the first backup runs.
    func startFirstBackup() async {
        guard step == .done, draft.progress.kitSaved, let plan = draft.plan, let supervisor else { return }
        await act {
            if planStatus?.plan != plan, let problem = await save(plan) { return problem }
            // Handed over before the kit is confirmed, so the scheduler can't start the first backup without it. The
            // agent removes these only after a backup that succeeds (Task 14b).
            if let choice = draft.progress.earlierRemoval {
                let request = EarlierSnapshotsRequest(planID: plan.id, confirmation: choice)
                if case .failure(let error) = await supervisor.connection.removeEarlierSnapshotsAfterNextBackup(request) {
                    return error.description
                }
            }
            let baseline = FirstBackupProgress.Baseline(planStatus)
            switch await supervisor.connection.confirmRecoveryKit(plan.id) {
            case .failure(let error): return error.description
            case .success: store.clear()
            }
            switch await supervisor.connection.backUpNow(plan.id) {
            case .failure(let error): return error.description
            case .success:
                firstBackupBaseline = baseline
                return nil
            }
        }
    }
}
