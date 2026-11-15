import Foundation

/// Which plan Settings → Plans shows, and the one guard every change of it goes through: the sidebar, the menu's
/// routes (a plan's line, "No off-Mac monitoring — Add…") and opening the app again. A request for another plan
/// while the shown one has unsaved edits doesn't drop them: it waits as `pending` until the user answers the
/// discard question (`confirm` or `cancel`).
///
/// `Tab` is the app's tab type: a route can name a plan's tab (the menu's "Add…" opens Alerts), which waits with its
/// plan and is handed back once the switch happens.
public struct PlanSelection<Tab: Sendable & Equatable>: Sendable, Equatable {
    /// A request waiting on the discard question. `planID` nil: no particular plan.
    public struct Pending: Sendable, Equatable {
        public var planID: UUID?
        public var tab: Tab?

        public init(planID: UUID?, tab: Tab?) {
            self.planID = planID
            self.tab = tab
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
    ///
    /// `landing`: the tab a request that asks for a plan opens on when it names no tab of its own (the Overview, for a
    /// sidebar pick or a plan opened from the menu, Task 14c); nil keeps the tab shown (Settings brought forward as it
    /// is). Returns the tab to show now, `tab ?? landing`, when the request was carried out or kept the plan shown;
    /// nil while it waits, and that tab is handed back by `confirm`.
    @discardableResult
    public mutating func request(_ planID: UUID?, tab: Tab? = nil, landing: Tab? = nil, editing: UUID?) -> Tab? {
        let shown = tab ?? landing
        if let editing {
            guard let planID, planID != editing else { return shown }
            pending = Pending(planID: planID, tab: shown)
            return nil
        }
        selected = planID
        pending = nil
        return shown
    }

    /// "Discard Changes": the waiting request is carried out. Returns its tab, to show now.
    @discardableResult
    public mutating func confirm() -> Tab? {
        guard let pending else { return nil }
        selected = pending.planID
        self.pending = nil
        return pending.tab
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
