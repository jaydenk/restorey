import Foundation
import Observation
import RestoreyCore

/// The plan open in the main window's Plans: its edits (`PlanEdit`, where every decision is made) and the save in flight.
/// One per plan shown: switching plans or closing the window makes a new one or none, and `close` drops the typed
/// secrets at once. The tabs bind straight to `fields` and the secrets, which store what is typed unchanged.
@MainActor
@Observable
final class PlanEditModel {
    private(set) var edit: PlanEdit
    private(set) var saving = false
    /// A typed repository password is being tried on the repository (Ruling R2).
    private(set) var checkingPassword = false
    /// The last save's sentence. Any edit clears it, so it never hides the current problem.
    private(set) var saveError: String?
    /// The password field's sentence after its check failed; cleared when the password is typed again.
    private(set) var passwordProblem: String?

    @ObservationIgnored private let connection: AgentConnection

    init(plan: Plan, connection: AgentConnection) {
        edit = PlanEdit(plan: plan)
        self.connection = connection
    }

    var planID: UUID { edit.planID }
    var saved: Plan { edit.saved }

    var fields: PlanEdit.Fields {
        get { edit.fields }
        set {
            edit.fields = newValue
            saveError = nil
        }
    }

    /// The plan limit's unit: choosing another converts the typed amount (`PlanEdit.setUploadLimitUnit`).
    var uploadLimitUnit: UploadLimitUnit {
        get { edit.fields.uploadLimitUnit }
        set {
            edit.setUploadLimitUnit(newValue)
            saveError = nil
        }
    }

    func secret(_ key: SecretKey) -> String { edit.secret(key) }

    func setSecret(_ value: String, for key: SecretKey) {
        edit.setSecret(value, for: key)
        saveError = nil
        if key == .repositoryPassword(planID) { passwordProblem = nil }
    }

    /// The agent sent a newer copy of the plan.
    func rebase(on plan: Plan) { edit.rebase(on: plan) }

    func revert() {
        edit.revert()
        saveError = nil
        passwordProblem = nil
    }

    /// Sends the edits; on success the form starts again from the plan the agent saved (normalised by it) and the
    /// typed secrets go. A typed repository password is tried on the repository first, and nothing is saved unless
    /// the repository opens with it. A refusal keeps everything as typed, so it can be corrected and saved again.
    func save() async {
        guard !saving else { return }
        let request: SavePlanRequest
        switch edit.request() {
        case .failure(let problem):
            saveError = problem.message
            return
        case .success(let built):
            request = built
        }
        saving = true
        saveError = nil
        defer { saving = false }
        if let credentials = edit.credentialsToCheck {
            checkingPassword = true
            let probe = await connection.probeRepositoryCredentials(planID, secrets: credentials)
            checkingPassword = false
            switch probe {
            case .success(let found):
                if let problem = PlanEdit.passwordProblem(after: found.state) {
                    passwordProblem = problem
                    saveError = problem
                    return
                }
            case .failure(let error):
                saveError = FormValidation.sentence(error.description) + " Nothing was saved."
                return
            }
        }
        switch await connection.savePlan(request) {
        case .success(let status):
            edit.didSave(status.plans.first { $0.plan.id == request.plan.id }?.plan ?? request.plan)
            passwordProblem = nil
        case .failure(let error):
            saveError = FormValidation.sentence(error.description)
        }
    }

    /// The plan is no longer shown: the secrets go now, not when SwiftUI lets go of the model.
    func close() { edit.close() }
}
