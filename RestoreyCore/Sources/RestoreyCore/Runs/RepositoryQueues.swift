import Foundation

/// Serialises every restic command for a repository (spec §5.3), so the weekly exclusive-lock
/// `check` never collides with an hourly `backup`. Work for one key runs strictly one at a time
/// in FIFO order; different keys run concurrently.
///
/// Each key has a chain of `Task`s, each awaiting its predecessor, so no lock is held across an
/// `await`. A job that throws still completes its link, so the chain never wedges.
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

    public func run<T: Sendable, E: Error>(
        repository key: String,
        _ work: @escaping @Sendable () async throws(E) -> T
    ) async throws(E) -> T {
        let previous = tails[key]?.task
        let job = Task<Result<T, E>, Never> {
            await previous?.value
            do throws(E) { return .success(try await work()) } catch { return .failure(error) }
        }
        nextID += 1
        let id = nextID
        tails[key] = Tail(id: id, task: Task { _ = await job.value })

        let result = await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
        // Drop the entry once nothing newer has been queued behind this job.
        if tails[key]?.id == id { tails[key] = nil }
        return try result.get()
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
        // "s3:" + scheme "://" host [/ bucket / prefix]
        guard s.hasPrefix("s3:"), let schemeEnd = s.range(of: "://") else { return s }
        let scheme = s[s.index(s.startIndex, offsetBy: 3)..<schemeEnd.lowerBound]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter }) else { return s }
        let rest = s[schemeEnd.upperBound...]
        let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        return "s3:" + scheme.lowercased() + "://" + rest[..<hostEnd].lowercased() + rest[hostEnd...]
    }
}
