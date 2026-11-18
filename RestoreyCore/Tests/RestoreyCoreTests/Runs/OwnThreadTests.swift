import Dispatch
import Foundation
import Testing
@testable import RestoreyCore

/// Task 18: blocking work on a thread of its own, raced against a deadline that needs no pool's free thread (the
/// marked-items scan, the cloud-only count, the app's move).
struct OwnThreadTests {
    @Test func theWorksResultWinsWhenItComesFirst() async {
        let value = await OwnThread.run(named: "test", qualityOfService: .utility, deadline: 60, orElse: -1) { 7 }
        #expect(value == 7)
    }

    /// With GCD's constrained global queues starved, as on a busy few-core Mac, the deadline still ends the wait;
    /// the work, held until after, finishes on its own thread and its result is dropped.
    @Test func theDeadlineWinsWhileGlobalQueuesAreStarved() async {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let starvation = GlobalQueueStarvation()
        let value = await OwnThread.run(named: "test", qualityOfService: .utility, deadline: 0.1, orElse: -1) {
            // The timeout only keeps a failing run from hanging. The starvation ends here too, off the pool, in case
            // the test's own code is waiting for a Swift concurrency thread that something starved holds.
            _ = release.wait(timeout: .now() + 5)
            starvation.end()
            finished.signal()
            return 7
        }
        starvation.end()
        release.signal()
        #expect(value == -1)
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { finished.wait() }
    }

    @Test func theWorkRunsOnItsOwnNamedThread() async {
        let name = await OwnThread.run(named: "Restorey test thread", qualityOfService: .utility) {
            Thread.current.name
        }
        #expect(name == "Restorey test thread")
    }
}
