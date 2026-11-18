import Darwin
import Dispatch
import Synchronization

/// Starves GCD's constrained global queues in this process, as a busy few-core Mac does (the GitHub runner, task 18),
/// without using any CPU: it parks blocks on `DispatchQueue.global(qos:)` that wait on a semaphore until `end()`.
///
/// The kernel gives the constrained (non-overcommit) global queues at most `kern.wq_max_constrained_threads` threads
/// per process (64 on macOS 27), so once that many park, every later block on any constrained global queue waits.
/// More are queued than the cap, so the queue always has parked blocks ahead of anything submitted after them (it is
/// FIFO): the starvation holds even while threads are still being created, and whatever other tests hold.
final class GlobalQueueStarvation: Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let count: Int
    private let ended = Mutex(false)

    init(qos: DispatchQoS.QoSClass = .utility) {
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.wq_max_constrained_threads", &limit, &size, nil, 0) != 0 || limit <= 0 { limit = 64 }
        count = Int(limit) + 16
        for _ in 0..<count {
            DispatchQueue.global(qos: qos).async { [release] in release.wait() }
        }
    }

    /// Lets every parked block go (and the ones still queued, as they start). Once: later calls do nothing.
    func end() {
        guard ended.withLock({ let was = $0; $0 = true; return !was }) else { return }
        for _ in 0..<count { release.signal() }
    }
}
