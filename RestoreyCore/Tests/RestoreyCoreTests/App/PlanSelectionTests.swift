import Foundation
import Testing
@testable import RestoreyCore

/// Settings → Plans: every change of the plan shown (the sidebar, the menu's routes, a reopen) goes through one
/// guard, so unsaved edits are never dropped without asking.
struct PlanSelectionTests {
    private let first = UUID()
    private let second = UUID()

    @Test func withNothingUnsavedARequestIsCarriedOut() {
        var selection = PlanSelection<String>()
        selection.request(first, editing: nil)
        #expect(selection.selected == first)
        #expect(selection.pending == nil)
        selection.request(second, editing: nil)
        #expect(selection.selected == second)
    }

    @Test func anotherPlanWhileEditingWaitsForTheAnswer() {
        var selection = PlanSelection<String>()
        selection.request(first, editing: nil)
        selection.request(second, editing: first)
        #expect(selection.selected == first)
        #expect(selection.pending == PlanSelection<String>.Pending(planID: second, tab: nil))
        selection.confirm()
        #expect(selection.selected == second)
        #expect(selection.pending == nil)
    }

    @Test func cancellingKeepsThePlanBeingEdited() {
        var selection = PlanSelection<String>()
        selection.request(first, editing: nil)
        selection.request(second, editing: first)
        selection.cancel()
        #expect(selection.selected == first)
        #expect(selection.pending == nil)
        selection.confirm()
        #expect(selection.selected == first)
    }

    /// The same plan, or no particular plan (a route naming only a section), keeps the edits and asks nothing.
    @Test func theSamePlanOrNoneAsksNothing() {
        var selection = PlanSelection<String>()
        selection.request(first, editing: nil)
        selection.request(first, editing: first)
        #expect(selection.selected == first)
        #expect(selection.pending == nil)
        selection.request(nil, editing: first)
        #expect(selection.selected == first)
        #expect(selection.pending == nil)
        selection.request(nil, editing: nil)
        #expect(selection.selected == nil)
    }

    /// The plan being edited is the one the editor holds, which may be shown while nothing was selected (the first
    /// plan by default): a request for another still waits.
    @Test func editingTheDefaultPlanStillAsks() {
        var selection = PlanSelection<String>()
        selection.request(second, editing: first)
        #expect(selection.selected == nil)
        #expect(selection.pending == PlanSelection<String>.Pending(planID: second, tab: nil))
    }

    /// The plan with the edits was deleted: its edits go with it, so nothing is asked.
    @Test func forgettingThePlanClearsAnyQuestion() {
        var selection = PlanSelection<String>()
        selection.request(first, editing: nil)
        selection.request(second, editing: first)
        selection.forget()
        #expect(selection.selected == nil)
        #expect(selection.pending == nil)
    }

    /// Fix round 2: a route that names a tab (the menu's "Add…" opens Alerts) keeps it while it waits, and the tab is
    /// applied only once the switch happens.
    @Test func aRoutesTabWaitsWithItsPlan() {
        var selection = PlanSelection<String>()
        #expect(selection.request(first, tab: "alerts", editing: nil) == "alerts")
        #expect(selection.request(second, tab: "alerts", editing: first) == nil)
        #expect(selection.pending == PlanSelection<String>.Pending(planID: second, tab: "alerts"))
        #expect(selection.confirm() == "alerts")
        #expect(selection.selected == second)
        #expect(selection.request(first, tab: "keep", editing: second) == nil)
        selection.cancel()
        #expect(selection.confirm() == nil)
        // No tab asked for: none to apply.
        #expect(selection.request(first, editing: nil) == nil)
    }
}
