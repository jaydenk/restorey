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

    // MARK: Per plan

    private static func status(_ phases: [(UUID, PlanPhase)]) -> AgentStatus {
        let plans = phases.map { id, phase in
            var plan = Plan.newHotPlan(
                name: "P", repository: .raw(repository: "/tmp/r", environmentNames: []), origin: .created,
                hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: t0)
            plan.id = id
            return PlanStatus(plan: plan, phase: phase, lastRecord: nil, nextRunAt: nil, alerts: [])
        }
        return AgentStatus(plans: plans, configError: nil, fdaMissing: false, generatedAt: t0)
    }

    private static func running(_ bytes: Int) -> PlanPhase {
        .running(BackupStatus(percentDone: 0.5, totalBytes: 100_000_000, bytesDone: bytes), retrying: nil)
    }

    /// Every status adds a sample for each running plan with progress; a plan that stops running is forgotten,
    /// so its next run starts from nothing.
    @Test func ratesFollowEachRunningPlan() {
        let a = UUID(), b = UUID()
        var rates = ProgressRates()
        rates.add(Self.status([(a, Self.running(0)), (b, .running(nil, retrying: nil))]), at: Self.t0)
        rates.add(Self.status([(a, Self.running(4_000_000)), (b, .idle)]), at: Self.t0.addingTimeInterval(2))
        #expect(rates.bytesPerSecond == [a: 2_000_000])
        rates.add(Self.status([(a, .idle)]), at: Self.t0.addingTimeInterval(3))
        #expect(rates.bytesPerSecond.isEmpty)
        rates.add(Self.status([(a, Self.running(50_000_000))]), at: Self.t0.addingTimeInterval(4))
        #expect(rates.bytesPerSecond.isEmpty, "a new run has a single sample")
    }

    /// A plan deleted mid-run is forgotten too.
    @Test func aPlanThatGoesIsForgotten() {
        let a = UUID()
        var rates = ProgressRates()
        rates.add(Self.status([(a, Self.running(0))]), at: Self.t0)
        rates.add(Self.status([(a, Self.running(1_000_000))]), at: Self.t0.addingTimeInterval(1))
        rates.add(Self.status([]), at: Self.t0.addingTimeInterval(2))
        #expect(rates.bytesPerSecond.isEmpty)
    }
}
