import Foundation
import RestoreyCore

/// Setup step "What to back up" (UI design §4 step 5).
extension SetupModel {
    var sources: [String] {
        get { draft.plan?.sources ?? [] }
        set { editPlan { $0.sources = newValue } }
    }

    var exclusions: [String] {
        get { draft.plan?.exclusions ?? [] }
        set { editPlan { $0.exclusions = newValue } }
    }

    var fileTypeExclusions: [String] {
        get { draft.plan?.fileTypeExclusions ?? [] }
        set { editPlan { $0.fileTypeExclusions = newValue } }
    }

    var oneFileSystem: Bool {
        get { draft.plan?.oneFileSystem ?? true }
        set { editPlan { $0.oneFileSystem = newValue } }
    }

    /// The build's identity, for the default exclusions (Restorey's own folders differ per identity).
    var identity: Identity? { supervisor?.identity }

    /// The new-group warning for an adopted repository (product spec §5.4), from the adoption report the
    /// progress keeps, so it survives a quit.
    var sourcesWarning: String? {
        guard let plan = draft.plan, plan.origin == .adopted, let report = draft.progress.adoption else { return nil }
        return SetupAdoption.newGroupWarning(hostLabel: plan.hostLabel, sources: plan.sources, report: report)
    }

    var sourcesProblem: String? { sources.isEmpty ? "Add at least one folder or drive to back up." : nil }

    func continueFromSources() async {
        guard step == .sources, sourcesProblem == nil, let plan = draft.plan else { return }
        await act {
            if let problem = await save(plan) { return problem }
            if schedule == nil, let saved = draft.plan { schedule = ScheduleForm(plan: saved) }
            go(to: .schedule)
            return nil
        }
    }
}
