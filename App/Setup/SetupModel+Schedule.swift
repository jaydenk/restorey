import Foundation
import RestoreyCore

/// Setup step "Schedule" (UI design §4 step 6).
extension SetupModel {
    /// The form starts from the plan as saved (a resumed setup, or after the sources step).
    func prepareSchedule() {
        if schedule == nil, let plan = draft.plan { schedule = ScheduleForm(plan: plan) }
    }

    var checkInProblem: String? { ScheduleForm.checkInProblem(secret(.checkInURL(planID))) }

    var scheduleProblem: String? {
        guard let schedule else { return nil }
        if case .failure(let problem) = schedule.retention { return problem.message }
        return checkInProblem
    }

    func continueFromSchedule() async {
        guard step == .schedule, let schedule, scheduleProblem == nil, let saved = draft.plan else { return }
        await act {
            var plan: Plan
            switch schedule.applied(to: saved) {
            case .failure(let problem): return problem.message
            case .success(let applied): plan = applied
            }
            let intent: CheckInIntent
            do {
                // "Remove" then a new URL typed is a replacement, not both at once.
                let field = secret(.checkInURL(plan.id))
                intent = try checkInIntent(
                    existing: plan.hasCheckInURL, field: field, remove: removeCheckInURL && field.isEmpty)
            } catch {
                return "\(error)"
            }
            plan.hasCheckInURL = intent.hasCheckInURL
            let secrets = intent.secret.map { [SecretEntry(key: .checkInURL(plan.id), value: $0)] } ?? []
            if let problem = await save(plan, secrets: secrets) { return problem }
            removeCheckInURL = false
            go(to: .done)
            return nil
        }
    }
}
