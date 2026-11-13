import Foundation
import Observation
import RestoreyCore

/// The plan open in Settings → Plans: its edits (`PlanEdit`, where every decision is made) and the save in flight.
/// One per plan shown: switching plans or closing the window makes a new one or none, and `close` drops the typed
/// secrets at once. The tabs bind straight to `fields` and the secrets, which store what is typed unchanged.
@MainActor
@Observable
final class PlanEditModel {
    private(set) var edit: PlanEdit
    private(set) var saving = false
    /// The last save's sentence, cleared by the next edit's save or a revert.
    private(set) var saveError: String?

    @ObservationIgnored private let connection: AgentConnection

    init(plan: Plan, connection: AgentConnection) {
        edit = PlanEdit(plan: plan)
        self.connection = connection
    }

    var planID: UUID { edit.planID }
    var saved: Plan { edit.saved }

    var fields: PlanEdit.Fields {
        get { edit.fields }
        set { edit.fields = newValue }
    }

    func secret(_ key: SecretKey) -> String { edit.secret(key) }

    func setSecret(_ value: String, for key: SecretKey) { edit.setSecret(value, for: key) }

    /// The agent sent a newer copy of the plan.
    func rebase(on plan: Plan) { edit.rebase(on: plan) }

    func revert() {
        edit.revert()
        saveError = nil
    }

    /// Sends the edits; on success the form starts again from the plan the agent saved (normalised by it) and the
    /// typed secrets go. A refusal keeps everything as typed, so it can be corrected and saved again.
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
        switch await connection.savePlan(request) {
        case .success(let status):
            edit.didSave(status.plans.first { $0.plan.id == request.plan.id }?.plan ?? request.plan)
        case .failure(let error):
            saveError = FormValidation.sentence(error.description)
        }
    }

    /// The plan is no longer shown: the secrets go now, not when SwiftUI lets go of the model.
    func close() { edit.close() }
}
