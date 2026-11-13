import Foundation
import RestoreyCore

/// Setup step "Where backups go" (UI design §4 step 2).
extension SetupModel {
    /// An environment row's typed value, held by row until "Check" names its keychain item.
    func environmentValue(_ row: UUID) -> String { draft.environmentValue(row) ?? "" }

    /// Stores what was typed as it is (the fields' binding rule): empty is no value.
    func setEnvironmentValue(_ value: String, for row: UUID) {
        draft.setEnvironmentValue(value.isEmpty ? nil : value, for: row)
    }

    /// Whether an empty key field keeps the saved key: only while the form still shows the saved address.
    var keepsSavedSecrets: Bool { storage.keepsSavedSecrets(saved: draft.plan?.repository) }

    /// "Check": saves the plan (its kit unconfirmed, so it never runs) with the backend's secrets, then asks
    /// the agent what is at the address (Ruling P2-2). A new plan, or one whose address changed, gets a
    /// generated stand-in password for the probe: restic needs one even to find nothing, and a repository
    /// that is there refuses it (`.passwordRejected`), which is how setup learns one is there. The password
    /// step replaces it. A changed address also forgets what was created or adopted at the old one.
    func check() async {
        guard step == .storage, let repository = storage.repositoryValue, let supervisor else { return }
        await act {
            let id = planID
            let sameRepository = draft.plan?.repository == repository
            let typed: [SecretEntry]
            switch storage.secretEntries(
                planID: id, typed: { self.draft.secret($0) }, environmentValue: { self.draft.environmentValue($0) },
                saved: sameRepository)
            {
            case .failure(let problem): return problem.message
            case .success(let entries): typed = entries
            }
            var plan: Plan
            var secrets = typed
            if var saved = draft.plan {
                saved.repository = repository
                if !sameRepository { saved.name = StorageForm.planName(for: repository) }
                plan = saved.origin == .created ? SetupAdoption.created(saved) : saved
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser
                plan = Plan.newHotPlan(
                    name: StorageForm.planName(for: repository), repository: repository, origin: .created,
                    hostLabel: thisMacNames.first ?? "Mac", sources: [home.path],
                    exclusions: DefaultExclusions.paths(home: home, identity: supervisor.identity), now: Date())
                plan.id = id
            }
            if !sameRepository {
                secrets.append(SecretEntry(key: .repositoryPassword(id), value: PasswordGenerator.make()))
            }
            if let problem = await save(plan, secrets: secrets) { return problem }
            if !sameRepository { draft.forgetRepository() }
            draft.setPlanID(id)
            store.save(draft.progress)
            switch await supervisor.connection.probeRepository(id) {
            case .failure(let error):
                return error.description
            case .success(let probe):
                draft.probe = probe
                if case .existing(let report) = probe.state { hostLabel = defaultHostLabel(report) }
                go(to: .password)
                return nil
            }
        }
    }
}
