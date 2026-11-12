import Foundation

/// Serialises every restic command for a repository (spec §5.3), so the weekly exclusive-lock
/// `check` never collides with an hourly `backup`. Work for one key runs strictly one at a time
/// in FIFO order; different keys run concurrently.
///
/// Each key has a chain of `Task`s, each awaiting its predecessor, so no lock is held across an
/// `await`. A job that throws still completes its link, so the chain never wedges.
///
/// Each job's work runs on a detached task, never on this actor, so a long synchronous job cannot
/// block queueing or a job for another key.
///
/// Cancellation: a caller cancelled while waiting in line does not leave the queue. Its job still
/// takes its turn, with cancellation delivered to the work (`Task.isCancelled` is true), and the
/// work decides how to react; restic runs are cancellation-safe and return promptly. Skipping the
/// job instead would force `run` to invent an error outside the work's own error type.
public actor RepositoryQueues {
    private struct Tail {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private var tails: [String: Tail] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Number of keys with work queued or running. For tests.
    var pendingKeyCount: Int { tails.count }

    /// A queued job. `value()` waits for it, forwarding the caller's cancellation to the work.
    public struct Job<T: Sendable, E: Error>: Sendable {
        fileprivate let queues: RepositoryQueues
        fileprivate let key: String
        fileprivate let id: UInt64
        fileprivate let task: Task<Result<T, E>, Never>

        /// Cancels the work (it still takes its turn; see the type documentation).
        public func cancel() { task.cancel() }

        public func value() async throws(E) -> T {
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            await queues.finished(key: key, id: id)
            return try result.get()
        }
    }

    /// Queues `work` behind everything already queued for `key` and returns at once, so callers
    /// can fix the enqueue order before awaiting. The work runs off this actor.
    public func enqueue<T: Sendable, E: Error>(
        repository key: String,
        _ work: @escaping @Sendable () async throws(E) -> T
    ) -> Job<T, E> {
        let previous = tails[key]?.task
        let task = Task.detached { () async -> Result<T, E> in
            await previous?.value
            do throws(E) { return .success(try await work()) } catch { return .failure(error) }
        }
        nextID += 1
        let id = nextID
        tails[key] = Tail(id: id, task: Task { _ = await task.value })
        return Job(queues: self, key: key, id: id, task: task)
    }

    public func run<T: Sendable, E: Error>(
        repository key: String,
        _ work: @escaping @Sendable () async throws(E) -> T
    ) async throws(E) -> T {
        let job = enqueue(repository: key, work)
        return try await job.value()
    }

    /// Drops the entry once nothing newer has been queued behind this job.
    fileprivate func finished(key: String, id: UInt64) {
        if tails[key]?.id == id { tails[key] = nil }
    }

    /// Case-normalises only the scheme and host of an S3 address (bucket and prefix are
    /// case-sensitive) and strips a trailing `/`. Shapes it doesn't recognise lose only the
    /// trailing `/`.
    public static func key(for repository: Repository) -> String {
        normalise(repository.resticRepository)
    }

    private static func normalise(_ string: String) -> String {
        var s = string
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        guard s.hasPrefix("s3:") else { return s }
        let body = s.dropFirst(3)
        // restic defaults a scheme-less endpoint to https.
        var scheme = "https"
        var rest = Substring(body)
        if let r = body.range(of: "://") {
            let given = body[body.startIndex..<r.lowerBound]
            guard !given.isEmpty, given.allSatisfy({ $0.isLetter }) else { return s }
            scheme = given.lowercased()
            rest = body[r.upperBound...]
        }
        let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[..<hostEnd].lowercased()
        guard !host.isEmpty else { return s }
        for (name, port) in [("https", ":443"), ("http", ":80")] where scheme == name && host.hasSuffix(port) {
            host.removeLast(port.count)
        }
        return "s3:" + scheme + "://" + host + rest[hostEnd...]
    }
}
