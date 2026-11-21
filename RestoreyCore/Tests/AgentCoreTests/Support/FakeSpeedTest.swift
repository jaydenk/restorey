import Foundation
@testable import AgentCore
import RestoreyCore

/// A stand-in for `networkQuality` (never the real tool): counts its calls, gives `results` in turn (the last one
/// again once they run out) stamped with `now`, and, while `hold` is set, waits for it before answering.
final class FakeSpeedTest: Sendable {
    /// A result in bits per second, or a failure.
    typealias Outcome = Result<Double, SpeedTestError>

    let calls = Locked(0)
    /// Calls that have answered.
    let answered = Locked(0)
    /// When set, each call waits for it to open.
    let hold = Locked<Gate?>(nil)
    private let results: Locked<[Outcome]>
    private let now: @Sendable () -> Date

    init(_ results: [Outcome] = [.success(320_000_000)], now: @escaping @Sendable () -> Date) {
        self.results = Locked(results)
        self.now = now
    }

    func run() async -> Result<UploadSpeedMeasurement, SpeedTestError> {
        calls.mutate { $0 += 1 }
        if let gate = hold.value { await gate.wait() }
        var outcome: Outcome = .failure(.unreadable)
        results.mutate { list in
            guard let first = list.first else { return }
            outcome = first
            if list.count > 1 { list.removeFirst() }
        }
        answered.mutate { $0 += 1 }
        return outcome.map { UploadSpeedMeasurement(bitsPerSecond: $0, bytesSent: 40_000_000, measuredAt: now()) }
    }

    /// Gives `results` in turn from the next call.
    func answer(with results: [Outcome]) {
        self.results.set(results)
    }

    /// Holds every call from now until the returned gate opens.
    func holdCalls() -> Gate {
        let gate = Gate()
        hold.set(gate)
        return gate
    }
}
