import Foundation
import Testing
@testable import RestoreyCore

struct ProgressRateTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nilWithFewerThanTwoSamples() {
        var rate = ProgressRate()
        #expect(rate.bytesPerSecond == nil)
        rate.add(bytesDone: 5, at: Self.t0)
        #expect(rate.bytesPerSecond == nil)
    }

    @Test func averagesOverTheSamples() {
        var rate = ProgressRate()
        rate.add(bytesDone: 0, at: Self.t0)
        rate.add(bytesDone: 10_000_000, at: Self.t0.addingTimeInterval(1))
        rate.add(bytesDone: 30_000_000, at: Self.t0.addingTimeInterval(2))
        #expect(rate.bytesPerSecond == 15_000_000)
    }

    @Test func onlyTheLastTenSecondsCount() {
        var rate = ProgressRate()
        rate.add(bytesDone: 0, at: Self.t0)
        // A burst early on, then a steady 1 MB/s from t+5 s to t+15 s.
        rate.add(bytesDone: 100_000_000, at: Self.t0.addingTimeInterval(5))
        rate.add(bytesDone: 105_000_000, at: Self.t0.addingTimeInterval(10))
        rate.add(bytesDone: 110_000_000, at: Self.t0.addingTimeInterval(15))
        #expect(rate.bytesPerSecond == 1_000_000)
    }

    @Test func resetsWhenBytesDoneGoesBackwards() {
        var rate = ProgressRate()
        rate.add(bytesDone: 0, at: Self.t0)
        rate.add(bytesDone: 10_000_000, at: Self.t0.addingTimeInterval(1))
        rate.add(bytesDone: 1_000, at: Self.t0.addingTimeInterval(2))
        #expect(rate.bytesPerSecond == nil)
        rate.add(bytesDone: 2_001_000, at: Self.t0.addingTimeInterval(3))
        #expect(rate.bytesPerSecond == 2_000_000)
    }

    @Test func nilWhenNoTimeHasPassed() {
        var rate = ProgressRate()
        rate.add(bytesDone: 0, at: Self.t0)
        rate.add(bytesDone: 10, at: Self.t0)
        #expect(rate.bytesPerSecond == nil)
    }
}
