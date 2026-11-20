import Foundation
import Testing
@testable import RestoreyCore

struct AgentPresentationTests {
    private static let all: [AgentHealthState] = [
        .checking, .healthy, .updating, .waitingForUpdate, .switchedOff, .notRunning(reachable: false),
        .notRunning(reachable: true), .waitingForRunningBackup(longWait: false), .waitingForRunningBackup(longWait: true), .damaged, .failed("x"),
    ]

    // MARK: Refetching status

    /// Ruling R51: every return to healthy fetches a fresh status, so lines from before a re-register or
    /// a drain are never shown as live.
    @Test func refetchesOnEveryTransitionIntoHealthy() {
        for previous in Self.all where previous != .healthy {
            #expect(shouldRefetchStatus(previous: previous, next: .healthy), "\(previous)")
        }
        #expect(!shouldRefetchStatus(previous: .healthy, next: .healthy))
        for next in Self.all where next != .healthy {
            #expect(!shouldRefetchStatus(previous: .healthy, next: next), "\(next)")
        }
    }
}
