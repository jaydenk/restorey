import Foundation

/// Upload speed for one running backup: the rate over the last ten seconds (first to last sample in that window).
/// restic reports bytes done twice a second (`RESTIC_PROGRESS_FPS=2`), which is too jumpy to show as is.
public struct ProgressRate: Sendable, Equatable {
    /// How far back the average reaches.
    public static let window: TimeInterval = 10

    private var samples: [(bytesDone: Int, at: Date)] = []

    public init() {}

    /// Adds a sample. `bytesDone` going backwards means a new run has begun, so earlier samples are dropped.
    public mutating func add(bytesDone: Int, at: Date) {
        if let last = samples.last, bytesDone < last.bytesDone { samples.removeAll() }
        samples.append((bytesDone, at))
        samples.removeAll { at.timeIntervalSince($0.at) > Self.window }
    }

    /// Nil with fewer than two samples, or when no time separates the first and last.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds > 0 else { return nil }
        return Double(last.bytesDone - first.bytesDone) / seconds
    }

    public static func == (lhs: ProgressRate, rhs: ProgressRate) -> Bool {
        lhs.samples.count == rhs.samples.count
            && zip(lhs.samples, rhs.samples).allSatisfy { $0.bytesDone == $1.bytesDone && $0.at == $1.at }
    }
}

/// The upload speed of every running backup, fed from each status as it arrives.
public struct ProgressRates: Sendable, Equatable {
    private var rates: [UUID: ProgressRate] = [:]

    public init() {}

    /// A sample for each running plan that has reported progress. A plan that is no longer running (or no longer
    /// exists) is forgotten, so its next run starts from nothing.
    public mutating func add(_ status: AgentStatus, at now: Date) {
        var next: [UUID: ProgressRate] = [:]
        for plan in status.plans {
            guard case .running(let progress?, _) = plan.phase else { continue }
            var rate = rates[plan.plan.id] ?? ProgressRate()
            rate.add(bytesDone: progress.bytesDone, at: now)
            next[plan.plan.id] = rate
        }
        rates = next
    }

    /// For `MenuPresentation.make`: only the plans with a rate.
    public var bytesPerSecond: [UUID: Double] {
        rates.compactMapValues(\.bytesPerSecond)
    }
}
