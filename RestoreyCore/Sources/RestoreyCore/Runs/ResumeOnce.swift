import Synchronization

/// Resumes a continuation the first time it is asked to, and ignores every later call: for racing a blocking job on
/// its own thread against a deadline (the cloud-only count, the marked-items scan).
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
