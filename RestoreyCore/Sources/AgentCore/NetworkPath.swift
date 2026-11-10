import RestoreyCore
import Synchronization

/// The latest network path, as the agent's `NWPathMonitor` reports it, and the waits for it to be
/// satisfied. The monitor stays in the agent and feeds `update(_:)`; this is the state machine.
///
/// Until the first update the path is unknown, which is neither online nor offline: a wait doesn't
/// return for it, and the scheduler waits (at most two minutes) before its first tick rather than
/// recording a "no network" skip on a path nobody has looked at yet.
public final class NetworkPath: Sendable {
    private struct State {
        /// Nil until the first update.
        var current: NetworkState?
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let lock = Mutex(State())

    public init() {}

    /// The latest reported path, or nil before the first update.
    public var current: NetworkState? { lock.withLock { $0.current } }

    /// What `preflight` sees. An unknown path is unsatisfied: a run only gets here before the first
    /// update if the scheduler's start-up wait timed out.
    public var forPreflight: NetworkState { current ?? .unsatisfied }

    /// How many waits are in progress. For tests.
    var waiterCount: Int { lock.withLock { $0.waiters.count } }

    /// Records a new path. A satisfied one wakes every wait.
    public func update(_ state: NetworkState) {
        let woken = lock.withLock { locked -> [CheckedContinuation<Void, Never>] in
            locked.current = state
            guard state != .unsatisfied else { return [] }
            defer { locked.waiters.removeAll() }
            return Array(locked.waiters.values)
        }
        for waiter in woken { waiter.resume() }
    }

    /// Returns once the path is satisfied (at once if it already is), or when the waiting task is
    /// cancelled. An unknown path is waited on.
    public func waitUntilSatisfied() async {
        let id = lock.withLock { locked in
            locked.nextID += 1
            return locked.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { locked in
                    if Task.isCancelled { return true }
                    if let current = locked.current, current != .unsatisfied { return true }
                    locked.waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}
