import Foundation
import RestoreyCore

/// Setup step "Recovery kit" (UI design §4 step 4, §7). The kit is the agent's `recoveryKit` reply for the plan
/// being set up, fetched when the step shows and dropped when it goes (`closeRecoveryKit`, from `go(to:)`,
/// `startAgain` and `close`). No Touch ID here: the user has just chosen or typed the password.
///
/// The tick only records `SetupProgress.kitSaved`; the agent's `confirmRecoveryKit` waits for Done's "Start
/// First Backup" (`SetupFlow`), so the plan can't run while its sources and schedule are still being chosen.
extension SetupModel {
    /// The kit can show only once the repository's own password is saved: this setup created the repository with
    /// it, or adopted one it opens (`PasswordStep.decide`'s recorded facts). Until then the plan holds the random
    /// stand-in "Check" saved, which opens nothing, and a kit showing it would be worse than none.
    var kitBlockedByStandInPassword: Bool { !repositoryReady }

    /// Fetches the kit when the step shows it. Waits for the plan first (a resumed setup), and does nothing while
    /// the stand-in password is all there is.
    func openRecoveryKit() async {
        await loadPlan()
        guard step == .recoveryKit, !kitBlockedByStandInPassword, let plan = draft.plan, let supervisor else { return }
        if recoveryKit?.planID != plan.id {
            closeRecoveryKit()
            recoveryKit = RecoveryKitModel(planID: plan.id, connection: supervisor.connection)
        }
        guard let kit = recoveryKit, kit.state == .idle else { return }
        await kit.load()
    }

    func closeRecoveryKit() {
        recoveryKit?.close()
        recoveryKit = nil
    }

    /// The tick can be set only once the kit has shown; clearing it is always allowed.
    var canTickKitSaved: Bool { kitSaved || recoveryKit?.document != nil }

    func continueFromRecoveryKit() {
        guard step == .recoveryKit, canContinue, !kitBlockedByStandInPassword else { return }
        go(to: SetupFlow.next(after: step, facts: facts))
    }

    /// Back to the password step, offered only while the stand-in password blocks the kit.
    func backToPassword() {
        guard step == .recoveryKit, kitBlockedByStandInPassword, !working else { return }
        go(to: .password)
    }
}
