import Dispatch
import Foundation
import Testing
@testable import RestoreyCore

/// Task 18: deadlines that need no free GCD thread. Each test parks every constrained global-queue thread the process
/// may have (`GlobalQueueStarvation`), as a busy few-core Mac does, and checks the deadline still ends the wait. A
/// deadline on `DispatchQueue.global` never fired here, and the stuck work's own result won.
///
/// The starvation is process-wide: while it lasts, no block on any constrained queue (global or private concurrent)
/// runs anywhere in the test process, so these must not run beside other tests. They are skipped unless
/// `RESTOREY_STARVATION_TESTS=1`, and `scripts/ci.sh` runs them on their own after the main run:
/// `RESTOREY_STARVATION_TESTS=1 swift test --package-path RestoreyCore --filter GlobalQueueStarvationTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RESTOREY_STARVATION_TESTS"] == "1"))
struct GlobalQueueStarvationTests {
    /// A query held until the test lets it go, after the look has returned, or for a second, which only keeps a
    /// failing run from hanging (the look then returns `.found`). The starvation also ends from a thread of its own,
    /// half a second after the query returns (so a deadline still starved can't beat the query's result), in case the
    /// test's own code is waiting for a Swift concurrency thread that something starved holds.
    final class Stuck: MarkedItemsFinding, Sendable {
        let gate = OneOutstandingGate()
        let release = DispatchSemaphore(value: 0)
        let starvation = GlobalQueueStarvation()
        func query(scopes: [String], limit: Int) -> MarkedItemsQuery {
            _ = release.wait(timeout: .now() + 1)
            Thread.detachNewThread { [starvation] in
                Thread.sleep(forTimeInterval: 0.5)
                starvation.end()
            }
            return .found([])
        }
        func isMarked(_ path: String) -> Bool { true }
    }

    @Test func theMarkedItemsDeadlineWinsWhileGlobalQueuesAreStarved() async {
        let stuck = Stuck()
        let result = await MarkedItemsScan.offPool(finder: stuck, sources: ["/Users/me"], deadline: 0.1)
        stuck.starvation.end()
        stuck.release.signal()
        #expect(result == .gaveUp)
    }

    /// `OwnThread`'s deadline, which the cloud-only count uses too.
    @Test func theOwnThreadDeadlineWinsWhileGlobalQueuesAreStarved() async {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let starvation = GlobalQueueStarvation()
        let value = await OwnThread.run(named: "test", qualityOfService: .utility, deadline: 0.1, orElse: -1) {
            // The timeout only keeps a failing run from hanging; the starvation ends here too, off the pool.
            _ = release.wait(timeout: .now() + 1)
            starvation.end()
            finished.signal()
            return 7
        }
        starvation.end()
        release.signal()
        #expect(value == -1)
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { finished.wait() }
    }
}
