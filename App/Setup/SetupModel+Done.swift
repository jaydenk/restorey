import Foundation
import RestoreyCore

/// Setup step "Done" (UI design §4 step 7).
extension SetupModel {
    var firstBackup: FirstBackupProgress? {
        guard let firstBackupBaseline else { return nil }
        return FirstBackupProgress.make(
            plan: planStatus, baseline: firstBackupBaseline, now: Date(),
            calendar: .current, locale: .current)
    }

    /// "Start first backup": saves anything not yet saved, then one call to the agent confirms the recovery kit the
    /// tick was given for (deferred from its step so the plan couldn't run mid-setup, `SetupFlow`) and starts the first
    /// backup together with it (Task 9). The agent checks the kit's digest against what it stores, so a kit whose
    /// details changed since it was shown is never confirmed: setup goes back to the kit step, which shows the new kit,
    /// with the agent's sentence. Confirming and starting are one step in the agent, so the scheduler never finds the
    /// plan due first. The plan is complete from the confirmation on, so the saved progress goes: there is nothing left
    /// to resume.
    func startFirstBackup() async {
        guard step == .done, draft.progress.kitSaved, let digest = draft.progress.kitDigest, let plan = draft.plan,
            let supervisor
        else { return }
        var detailsChanged = false
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
            switch await supervisor.connection.confirmRecoveryKit(plan.id, kitDigest: digest, startFirstBackup: true) {
            case .failure(.refused(RecoveryKitDocument.detailsChangedRefusal)):
                detailsChanged = true
                return nil
            case .failure(let error):
                return error.description
            case .success:
                store.clear()
                firstBackupBaseline = baseline
                return nil
            }
        }
        if detailsChanged {
            kitSaved = false
            go(to: .recoveryKit)
            stepError = RecoveryKitDocument.detailsChangedRefusal
        }
    }
}
