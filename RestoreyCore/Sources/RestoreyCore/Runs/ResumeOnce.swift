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
/// semaphore wait and is woken early when the work finishes. Neither needs a pool to have a free thread. The deadline's
/// thread runs at the caller's quality of service, but never below utility: the bounded work runs at utility, and a
/// background thread gets the least CPU and the most timer latency ("The system uses QoS information to adjust
/// priorities such as scheduling, CPU and I/O throughput, and timer latency", Apple, *Energy Efficiency Guide for Mac
/// Apps*), which would loosen the very bound it keeps. The thread only
/// sleeps and then resumes a continuation, so a higher class costs nothing. Work still running at the deadline finishes on its own thread
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
        let deadlineQoS = deadlineQualityOfService
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let finished = DispatchSemaphore(value: 0)
            start(name, qualityOfService) {
                once.resume(work())
                finished.signal()
            }
            start("\(name) deadline", deadlineQoS) {
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
    /// priority), raised to utility if lower (background, or unspecified). `QualityOfService`'s raw values are the QoS
    /// classes', except the default class, which has none of its own.
    static var deadlineQualityOfService: QualityOfService {
        let raw = max(qos_class_self().rawValue, QOS_CLASS_UTILITY.rawValue)
        return QualityOfService(rawValue: Int(raw)) ?? .default
    }
}

/// At most one outstanding run of blocking work that can hang and can't be stopped (review I2; task 18 fix round 1):
/// a Spotlight look, a cloud-only walk. Without it a hung `mds` or File Provider would leave one more blocked thread
/// behind every run, without limit. The gate holds the outstanding run's deadline: a run that arrives while one is
/// outstanding waits for it within its own deadline (two plans backing up together), but gives up at once when the
/// outstanding one has already outlived its deadline (stuck), so only that one thread is ever blocked.
public final class OneOutstandingGate: Sendable {
    /// The real Spotlight finder's, shared by every look in the process (the agent's backups, the app's Folders tab).
    public static let spotlight = OneOutstandingGate()

    /// The outstanding run's deadline; nil when none is outstanding.
    private let outstanding = Mutex<ContinuousClock.Instant?>(nil)

    public init() {}

    /// True while a run is outstanding.
    public var isBusy: Bool { outstanding.withLock { $0 != nil } }

    enum Entry: Equatable {
        case entered
        /// A run is outstanding, and is still within its deadline.
        case wait
        /// A run is outstanding past its deadline.
        case stuck
    }

    func enter(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Entry {
        outstanding.withLock { current in
            guard let current else {
                current = deadline
                return .entered
            }
            return now >= current ? .stuck : .wait
        }
    }

    /// True once this run holds the gate, with `deadline` as its own. While another is outstanding and within its
    /// deadline this waits for it (polling), within `deadline`; false, holding nothing, when the outstanding one is
    /// past its deadline, `deadline` passes, or the task is cancelled while waiting. The holder calls `leave()` only
    /// when its work has really returned, so a run abandoned at its deadline keeps the gate until then.
    public func enter(until deadline: ContinuousClock.Instant) async -> Bool {
        while true {
            let now = ContinuousClock.now
            switch enter(until: deadline, now: now) {
            case .entered: return true
            case .stuck: return false
            case .wait:
                if now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return false }
            }
        }
    }

    public func leave() { outstanding.withLock { $0 = nil } }
}
