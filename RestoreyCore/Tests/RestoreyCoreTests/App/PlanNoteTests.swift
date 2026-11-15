import Foundation
import Testing
@testable import RestoreyCore

/// The note under a plan's name in Settings' sidebar, and the stop shown on its page (live finding 3, build 812): a
/// stopped plan says so, in the menu's words ("Stopped" and the agent's reason).
struct PlanNoteTests {
    private static let now = Date(timeIntervalSince1970: 1_794_000_000)

    private static func status(_ phase: PlanPhase = .idle, setup: PlanSetupState = .complete) -> PlanStatus {
        let plan = Plan.newHotPlan(
            name: "Local · repo", repository: .raw(repository: "/Users/me/repo", environmentNames: []), origin: .created, hostLabel: "mac",
            sources: ["/Users/me"], exclusions: [], now: now)
        return PlanStatus(plan: plan, phase: phase, lastRecord: nil, nextRunAt: nil, alerts: [], setupState: setup)
    }

    @Test func aPlanWithNothingWrongHasNoNote() {
        #expect(PlanNote.sidebar(Self.status()) == nil)
        #expect(PlanNote.stop(Self.status()) == nil)
    }

    @Test func aStoppedPlanSaysSoWithTheReason() {
        let stopped = Self.status(.stopped(reason: "The repository password is wrong"))
        let note = PlanNote.sidebar(stopped)
        #expect(note == PlanNote(title: "Stopped", detail: "The repository password is wrong", level: .error))
        #expect(PlanNote.stop(stopped) == note)
    }

    @Test func setupNotFinishedAndANewKitKeepTheirWords() {
        #expect(PlanNote.sidebar(Self.status(setup: .unfinished))
            == PlanNote(title: "Setup not finished", detail: nil, level: .warning))
        #expect(PlanNote.sidebar(Self.status(setup: .needsNewKit))
            == PlanNote(title: "New recovery kit needed", detail: nil, level: .warning))
        #expect(PlanNote.stop(Self.status(setup: .needsNewKit)) == nil)
    }

    /// The stop is what keeps backups from running until it is fixed (the password, then the kit), so it is the one
    /// line the sidebar shows; an unfinished plan has no stop to speak of yet.
    @Test func aStopOutranksANewKitButNotUnfinishedSetup() {
        let reason = PlanPhase.stopped(reason: "The repository password is wrong")
        #expect(PlanNote.sidebar(Self.status(reason, setup: .needsNewKit))?.title == "Stopped")
        #expect(PlanNote.sidebar(Self.status(reason, setup: .unfinished))?.title == "Setup not finished")
    }

    @Test func runningPausedOrSkippedIsntAStop() {
        #expect(PlanNote.stop(Self.status(.paused(until: Self.now))) == nil)
        #expect(PlanNote.sidebar(Self.status(.running(nil, retrying: nil))) == nil)
    }
}
