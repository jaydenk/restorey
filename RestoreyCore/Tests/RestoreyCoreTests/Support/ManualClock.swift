import Synchronization

// The same clock as AgentCoreTests/Support/ManualClock.swift (test targets can't share a file).

/// A clock that only moves when a test calls `advance(by:)`. Sleepers wake when the time they wait for
/// is reached, and a cancelled sleep throws `CancellationError` at once.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// `sleepers(atLeast:)` calls waiting for that many sleeps.
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// How many sleeps are waiting.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, watchers) = state.withLock { state -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    let count = state.sleepers.count
                    let due = state.watchers.filter { $0.count <= count }.map(\.continuation)
                    state.watchers.removeAll { $0.count <= count }
                    return (nil, due)
                }
                if let outcome { continuation.resume(with: outcome) }
                for watcher in watchers { watcher.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Returns once at least `count` sleeps are waiting: the code under test has reached its timer. No polling, and no
    /// wall-clock time, so it doesn't depend on when the scheduler runs anything.
    func sleepers(atLeast count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state in
                if state.sleepers.count >= count { return true }
                state.watchers.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Moves time on and wakes every sleeper whose deadline has been reached.
    func advance(by duration: Duration) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due.map(\.continuation)
        }
        for continuation in woken { continuation.resume() }
    }
}
