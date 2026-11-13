import Foundation

/// Which plan Settings → Plans shows, and the one guard every change of it goes through: the sidebar, the menu's
/// routes (a plan's line, "No off-Mac monitoring — Add…") and opening the app again. A request for another plan
/// while the shown one has unsaved edits doesn't drop them: it waits as `pending` until the user answers the
/// discard question (`confirm` or `cancel`).
public struct PlanSelection: Sendable, Equatable {
    /// A request waiting on the discard question. `planID` nil: no particular plan.
    public struct Pending: Sendable, Equatable {
        public var planID: UUID?

        public init(planID: UUID?) {
            self.planID = planID
        }
    }

    /// The plan asked for; nil shows the first.
    public private(set) var selected: UUID?
    public private(set) var pending: Pending?

    public init(selected: UUID? = nil) {
        self.selected = selected
    }

    /// `editing`: the plan whose unsaved edits are open, or nil when nothing is unsaved. A request for a different
    /// plan then waits; one for the same plan, or for none in particular (a route that names only a section), keeps
    /// the plan being edited and asks nothing.
    public mutating func request(_ planID: UUID?, editing: UUID?) {
        if let editing {
            guard let planID, planID != editing else { return }
            pending = Pending(planID: planID)
            return
        }
        selected = planID
        pending = nil
    }

    /// "Discard Changes": the waiting request is carried out.
    public mutating func confirm() {
        guard let pending else { return }
        selected = pending.planID
        self.pending = nil
    }

    /// "Keep Editing": the waiting request is dropped.
    public mutating func cancel() {
        pending = nil
    }

    /// The plan shown is gone (deleted): back to the first plan, with nothing to ask about.
    public mutating func forget() {
        selected = nil
        pending = nil
    }
}
