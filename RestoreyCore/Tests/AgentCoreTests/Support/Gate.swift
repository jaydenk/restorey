import Synchronization

/// A one-shot latch: `wait()` suspends until `open()`, or returns at once once open. A cancelled wait
/// returns without the gate opening.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if state.isOpen || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

/// Polls `condition` (yielding, with 1 ms pauses) until it holds, for at most about two seconds.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
