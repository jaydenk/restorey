import Foundation
import RestoreyCore

/// Setup step "Repository password" (UI design §4 step 3). What it shows is `PasswordStep.decide`'s, from the
/// probe and the facts the progress records (`repositoryCreated`, `adoption`), never from the plan's origin.
extension SetupModel {
    var passwordStep: PasswordStep {
        PasswordStep.decide(probe: draft.probe?.state, progress: draft.progress, probeFailed: probeFailed)
    }

    /// Created or adopted by this setup (`SetupFacts.repositoryReady`).
    var repositoryReady: Bool { passwordStep == .ready }

    /// The password step shows what "Check" found; a resumed step probes again with the saved password, unless
    /// the progress already says this setup created or adopted the repository.
    /// A failed probe leaves the step on `.probeFailed`, whose "Try Again" calls this again.
    func probeIfNeeded() async {
        guard step == .password, passwordStep == .probing || passwordStep == .probeFailed, let plan = draft.plan,
            let supervisor
        else { return }
        await act {
            // Inside the action, so a refused `act` (another action running) leaves the step as it was.
            probeFailed = false
            switch await supervisor.connection.probeRepository(plan.id) {
            case .failure(let error):
                probeFailed = true
                return error.description
            case .success(let probe):
                setProbe(probe)
                if case .existing(let report) = probe.state {
                    // Opened with the password typed before the quit: still to be adopted. A plan already saved
                    // as adopted (the quit came during "Use This Repository") keeps the host label chosen then.
                    hostLabel = plan.origin == .adopted ? plan.hostLabel : defaultHostLabel(report)
                }
                return nil
            }
        }
    }

    /// The generated password offered for a new repository, made the first time the step shows it.
    func offerGeneratedPassword() {
        let key = SecretKey.repositoryPassword(planID)
        if secret(key).isEmpty { setSecret(PasswordGenerator.make(), for: key) }
    }

    func newGeneratedPassword() {
        setSecret(PasswordGenerator.make(), for: .repositoryPassword(planID))
    }

    /// Switching between the generated password and the user's own starts the field afresh. The recovery kit,
    /// next, shows the password as saved, so a mistyped one is seen there before anything is backed up.
    func chooseOwnPassword(_ own: Bool) {
        ownPassword = own
        setSecret(own ? "" : PasswordGenerator.make(), for: .repositoryPassword(planID))
    }

    var passwordProblem: String? {
        let password = secret(.repositoryPassword(planID))
        return password.isEmpty ? "Enter a password for the repository." : FormValidation.newRepositoryPassword(password)
    }

    /// "Create new repository" (product spec §5.4: never automatic): saves the password, then `restic init`.
    /// Success is recorded in the progress (`repositoryCreated`) before the step moves on.
    func createRepository() async {
        guard step == .password, passwordStep == .create, passwordProblem == nil, let saved = draft.plan,
            let supervisor
        else { return }
        await act {
            let password = SecretEntry(key: .repositoryPassword(saved.id), value: secret(.repositoryPassword(saved.id)))
            if let problem = await save(SetupAdoption.created(saved), secrets: [password]) { return problem }
            switch await supervisor.connection.createRepository(saved.id) {
            case .failure(let error): return error.description
            case .success:
                recordRepositoryCreated()
                go(to: .recoveryKit)
                return nil
            }
        }
    }

    /// The existing repository's "Open": saves the password typed, then probes with it.
    func openExistingRepository() async {
        let key = SecretKey.repositoryPassword(planID)
        guard step == .password, let saved = draft.plan, let supervisor, !secret(key).isEmpty else { return }
        await act {
            if let problem = await save(saved, secrets: [SecretEntry(key: key, value: secret(key))]) { return problem }
            setSecret("", for: key)
            switch await supervisor.connection.probeRepository(saved.id) {
            case .failure(let error): return error.description
            case .success(let probe):
                setProbe(probe)
                switch probe.state {
                case .existing(let report):
                    hostLabel = defaultHostLabel(report)
                    return nil
                case .passwordRejected: return "That password doesn't open the repository at this address"
                case .empty: return "The repository is no longer there: create a new one, or go back and check the address"
                }
            }
        }
    }

    var hostChoices: [String] {
        guard case .adopt(let report) = passwordStep else { return [] }
        return SetupAdoption.hostChoices(hosts: report.hosts, thisMac: thisMacNames)
    }

    func defaultHostLabel(_ report: AdoptReport) -> String {
        SetupAdoption.defaultHostLabel(hosts: report.hosts, thisMac: thisMacNames)
    }

    /// "Use this repository": the plan becomes an adopted one under the chosen host label, `adopt` lists its
    /// snapshots for that label, and the sources are pre-filled from the latest one (product spec §5.4). The
    /// report is kept in the progress for the sources step's new-group warning.
    func useExistingRepository() async {
        guard step == .password, case .adopt = passwordStep, let saved = draft.plan, let supervisor,
            FormValidation.hostLabel(hostLabel) == nil
        else { return }
        await act {
            let adopted = SetupAdoption.adopted(
                saved, hostLabel: hostLabel.trimmingCharacters(in: .whitespaces), now: Date())
            if let problem = await save(adopted) { return problem }
            switch await supervisor.connection.adopt(saved.id) {
            case .failure(let error): return error.description
            case .success(let report):
                var prefilled = draft.plan ?? adopted
                prefilled.sources = SetupAdoption.prefilledSources(report, current: prefilled.sources)
                // Recorded only once the pre-filled sources are saved too: until then the step stays on the
                // adopt path, and pressing the button again runs all of it again.
                if let problem = await save(prefilled) { return problem }
                recordAdoption(report)
                // The opt-in asks now, with the plan as adopted and pre-filled. Only a confirmed choice moves on: after
                // nothing to remove, a Cancel or a failure the step stays (now "ready") and says why.
                if applyRetentionToEarlier {
                    if let problem = await chooseEarlierRemoval(draft.plan ?? prefilled) { return problem }
                    guard earlierRemoval != nil else { return nil }
                }
                go(to: .recoveryKit)
                return nil
            }
        }
    }

    /// The password step's Continue, for a repository a resumed setup finds ready.
    func continueFromPassword() {
        guard step == .password, canContinue else { return }
        go(to: SetupFlow.next(after: step, facts: facts))
    }

    /// Back to the storage form, to correct the address. What was created or adopted stays recorded until
    /// "Check" saves a different address.
    func backToStorage() {
        guard step == .password, !working else { return }
        setProbe(nil)
        probeFailed = false
        go(to: .storage)
    }
}
