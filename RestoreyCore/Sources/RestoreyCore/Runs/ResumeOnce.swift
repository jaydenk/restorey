import Dispatch
import Foundation
import Synchronization

/// Resumes a continuation the first time it is asked to, and ignores every later call: for racing a blocking job on
/// its own thread against a deadline (`OwnThread`).
public final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    public init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = Mutex(continuation) }

    public func resume(_ value: Value) {
        let taken = continuation.withLock { state -> CheckedContinuation<Value, Never>? in
            defer { state = nil }
            return state
        }
        taken?.resume(returning: value)
    }
}

/// Blocking work (a synchronous system call that may hang: a Spotlight query, a file walk, a copy) run on a thread of
/// its own, never on a Swift concurrency thread or a GCD global queue (task 18).
///
/// - The cooperative pool is only as wide as the Mac has cores, so a blocked task there holds up every other task.
/// - GCD's global queues are constrained: a block runs only when the kernel admits another thread (fewer than one
///   active per core at that QoS or above, and at most `kern.wq_max_constrained_threads`, 64, in the process). On a
///   busy few-core Mac a block there, a deadline included, can wait as long as the work it was meant to bound.
///
/// So the work gets a `Thread` (a plain pthread, outside both pools), and the deadline another, which sleeps in a timed
/// semaphore wait and is woken early when the work finishes. Neither needs a pool to have a free thread; the deadline's
/// thread runs at the caller's quality of service. Work still running at the deadline finishes on its own thread
/// later, and its result is discarded, so it must touch nothing but its own state.
public enum OwnThread {
    /// `work`'s result, on a thread of its own at `qualityOfService`.
    public static func run<Value: Sendable>(
        named name: String, qualityOfService: QualityOfService, _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            start(name, qualityOfService) { continuation.resume(returning: work()) }
        }
    }

    /// `work`'s result, on a thread of its own at `qualityOfService`, or `timedOut` once `deadline` seconds have passed,
    /// whichever comes first.
    public static func run<Value: Sendable>(
        named name: String, qualityOfService: QualityOfService, deadline: TimeInterval, orElse timedOut: Value,
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        let callers = callersQualityOfService
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let finished = DispatchSemaphore(value: 0)
            start(name, qualityOfService) {
                once.resume(work())
                finished.signal()
            }
            start("\(name) deadline", callers) {
                if finished.wait(timeout: .now() + max(0, deadline)) == .timedOut { once.resume(timedOut) }
            }
        }
    }

    private static func start(_ name: String, _ qualityOfService: QualityOfService, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = qualityOfService
        thread.start()
    }

    /// The calling thread's QoS class (`qos_class_self`, which on a Swift concurrency thread follows the task's
    /// priority); `QualityOfService`'s raw values are the QoS classes', and the default class has none of its own.
    private static var callersQualityOfService: QualityOfService {
        QualityOfService(rawValue: Int(qos_class_self().rawValue)) ?? .default
    }
}
