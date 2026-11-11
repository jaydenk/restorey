import Testing
@testable import AgentCore
import RestoreyCore

/// The network path's state machine: unknown until the first update, and the waits for it to be satisfied.
@Suite(.timeLimit(.minutes(1)))
struct NetworkPathTests {
    @Test func unknownUntilTheFirstUpdateAndWaitedOn() async {
        let path = NetworkPath()
        #expect(path.current == nil)
        #expect(path.forPreflight == .unsatisfied)

        let waited = Task { await path.waitUntilSatisfied() }
        #expect(await eventually { path.waiterCount == 1 })
        // Offline is no better than unknown.
        path.update(.unsatisfied)
        for _ in 0..<20 { await Task.yield() }
        #expect(path.waiterCount == 1)

        path.update(.satisfied(constrained: true, expensive: false))
        await waited.value
        #expect(path.current == .satisfied(constrained: true, expensive: false))
        #expect(path.waiterCount == 0)
    }

    @Test func aSatisfiedPathWakesEveryWaiter() async {
        let path = NetworkPath()
        let finished = Locked(0)
        let waiters = (0..<3).map { _ in Task { await path.waitUntilSatisfied(); finished.mutate { $0 += 1 } } }
        #expect(await eventually { path.waiterCount == 3 })
        path.update(.satisfied(constrained: false, expensive: false))
        for waiter in waiters { await waiter.value }
        #expect(finished.value == 3)
    }

    @Test func aWaitReturnsAtOnceWhenAlreadySatisfied() async {
        let path = NetworkPath()
        path.update(.satisfied(constrained: false, expensive: true))
        await path.waitUntilSatisfied()
        #expect(path.waiterCount == 0)
        // Going offline again makes the next wait wait.
        path.update(.unsatisfied)
        let waited = Task { await path.waitUntilSatisfied() }
        #expect(await eventually { path.waiterCount == 1 })
        waited.cancel()
        await waited.value
    }

    /// Ruling R60: `update` reports the network coming back (unsatisfied to satisfied) and nothing else:
    /// not the first path after start-up, not a satisfied path that changes, not going offline.
    @Test func updateReportsOnlyTheNetworkComingBack() {
        let path = NetworkPath()
        #expect(path.update(.satisfied(constrained: false, expensive: false)) == false) // the first path
        #expect(path.update(.satisfied(constrained: true, expensive: false)) == false) // satisfied to satisfied
        #expect(path.update(.unsatisfied) == false)
        #expect(path.update(.unsatisfied) == false)
        #expect(path.update(.satisfied(constrained: false, expensive: true)) == true) // it came back
        #expect(path.update(.satisfied(constrained: false, expensive: false)) == false)

        // A first path that is offline, then online, is the network coming back.
        let offlineAtStart = NetworkPath()
        #expect(offlineAtStart.update(.unsatisfied) == false)
        #expect(offlineAtStart.update(.satisfied(constrained: false, expensive: false)) == true)
    }

    @Test func aWaitCancelledBeforeTheNetworkComesBackReturnsAndIsForgotten() async {
        let path = NetworkPath()
        let cancelled = Task { await path.waitUntilSatisfied() }
        let kept = Task { await path.waitUntilSatisfied() }
        #expect(await eventually { path.waiterCount == 2 })

        cancelled.cancel()
        await cancelled.value
        #expect(path.waiterCount == 1)

        path.update(.satisfied(constrained: false, expensive: false))
        await kept.value
        #expect(path.waiterCount == 0)
    }

    @Test func aWaitInAnAlreadyCancelledTaskReturnsAtOnce() async {
        let path = NetworkPath()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await path.waitUntilSatisfied()
        }
        await task.value
        #expect(path.waiterCount == 0)
    }
}
