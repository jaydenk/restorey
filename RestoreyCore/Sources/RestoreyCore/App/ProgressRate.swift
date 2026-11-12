import Foundation

/// Upload speed for one running backup, as a moving average over the last ten seconds of progress samples.
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
