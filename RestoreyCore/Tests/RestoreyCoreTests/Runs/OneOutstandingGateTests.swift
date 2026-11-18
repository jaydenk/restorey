import Foundation
import Testing
@testable import RestoreyCore

/// The gate's decisions, on given instants (no waiting).
struct OneOutstandingGateTests {
    @Test func aFreeGateIsEnteredWithinTheCallersDeadline() {
        let gate = OneOutstandingGate()
        let now = ContinuousClock.now
        #expect(gate.enter(until: now.advanced(by: .seconds(1)), now: now) == .entered)
        #expect(gate.isBusy)
    }

    /// Re-review N2: a caller that spent its whole budget waiting for an earlier run doesn't take the gate, which it
    /// would hold while its walk was abandoned at once.
    @Test func aCallerPastItsOwnDeadlineDoesntTakeAFreeGate() {
        let gate = OneOutstandingGate()
        let now = ContinuousClock.now
        #expect(gate.enter(until: now, now: now) == .expired)
        #expect(!gate.isBusy)
    }

    @Test func anOutstandingRunMakesOthersWaitUntilItsDeadlineThenReportsItStuck() {
        let gate = OneOutstandingGate()
        let now = ContinuousClock.now
        #expect(gate.enter(until: now.advanced(by: .seconds(1)), now: now) == .entered)
        #expect(gate.enter(until: now.advanced(by: .seconds(5)), now: now) == .wait)
        #expect(gate.enter(until: now.advanced(by: .seconds(5)), now: now.advanced(by: .seconds(2))) == .stuck)
        gate.leave()
        #expect(!gate.isBusy)
    }
}
