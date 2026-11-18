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

    /// Work still running at the deadline: the deadline's value, and the work, released after, finishes on its own
    /// thread with its result dropped. The same under GCD starvation is `GlobalQueueStarvationTests`.
    @Test func theDeadlineWinsOverWorkStillRunning() async {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let value = await OwnThread.run(named: "test", qualityOfService: .utility, deadline: 0.1, orElse: -1) {
            release.wait()
            finished.signal()
            return 7
        }
        release.signal()
        #expect(value == -1)
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { finished.wait() }
    }

    /// The deadline's thread is never below utility (a background one gets the most timer latency), and keeps a
    /// higher caller's class.
    @Test func theDeadlineThreadIsAtLeastUtility() async {
        let background = await OwnThread.run(named: "test", qualityOfService: .background) {
            OwnThread.deadlineQualityOfService
        }
        #expect(background == .utility)
        let userInitiated = await OwnThread.run(named: "test", qualityOfService: .userInitiated) {
            OwnThread.deadlineQualityOfService
        }
        #expect(userInitiated == .userInitiated)
    }

    @Test func theWorkRunsOnItsOwnNamedThread() async {
        let name = await OwnThread.run(named: "Restorey test thread", qualityOfService: .utility) {
            Thread.current.name
        }
        #expect(name == "Restorey test thread")
    }
}
