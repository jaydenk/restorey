import Foundation
import Testing
@testable import RestoreyCore

struct AgentPresentationTests {
    private static let all: [AgentHealthState] = [
        .checking, .healthy, .updating, .waitingForUpdate, .switchedOff, .notRunning(reachable: false),
        .notRunning(reachable: true), .damaged, .failed("x"),
    ]

    // MARK: Refetching status

    /// Ruling R51: every return to healthy fetches a fresh status, so lines from before a re-register or
    /// a drain are never shown as live.
    @Test func refetchesOnEveryTransitionIntoHealthy() {
        for previous in Self.all where previous != .healthy {
            #expect(shouldRefetchStatus(previous: previous, next: .healthy), "\(previous)")
        }
        #expect(!shouldRefetchStatus(previous: .healthy, next: .healthy))
        for next in Self.all where next != .healthy {
            #expect(!shouldRefetchStatus(previous: .healthy, next: next), "\(next)")
        }
    }

    @Test func planLinesOnlyWhileHealthy() {
        for state in Self.all {
            #expect(showsPlanLines(state) == (state == .healthy), "\(state)")
            #expect(allowsBackUpNow(state) == (state == .healthy), "\(state)")
        }
    }

    // MARK: Icon

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func status(
        _ phases: [PlanPhase], alerts: [AlertCondition] = [], configError: String? = nil
    ) -> AgentStatus {
        let plans = phases.enumerated().map { index, phase in
            PlanStatus(
                plan: Plan.newHotPlan(
                    name: "Plan \(index)", repository: .raw(repository: "/tmp/r\(index)", environmentNames: []),
                    origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now),
                phase: phase, lastRecord: nil, nextRunAt: nil, alerts: index == 0 ? alerts : [])
        }
        return AgentStatus(plans: plans, configError: configError, fdaMissing: nil, generatedAt: now)
    }

    @Test func neutralWhenAllIsWell() {
        #expect(statusIconState(health: .healthy, status: Self.status([.idle, .running(nil, retrying: nil)])) == .neutral)
        #expect(statusIconState(health: .healthy, status: Self.status([])) == .neutral)
        #expect(statusIconState(health: .healthy, status: nil) == .neutral)
        #expect(statusIconState(health: .healthy, status: Self.status([.paused(until: Self.now)])) == .neutral)
    }

    @Test func errorForAStoppedPlanOrAConfigError() {
        #expect(statusIconState(health: .healthy, status: Self.status([.idle, .stopped(reason: "Wrong password")])) == .error)
        #expect(statusIconState(health: .healthy, status: Self.status([.idle], configError: "corrupt")) == .error)
    }

    @Test func errorWhenTheAgentIsUnreachableOrBroken() {
        for state in [AgentHealthState.notRunning(reachable: false), .notRunning(reachable: true), .switchedOff,
                      .damaged, .failed("x")] {
            #expect(statusIconState(health: state, status: Self.status([.idle])) == .error, "\(state)")
        }
    }

    @Test func warningForASkipOrAMonitoringAlert() {
        #expect(statusIconState(health: .healthy, status: Self.status([.idle, .skipped(.onBattery)])) == .warning)
        for alert in [AlertCondition.notificationsOff, .checkInRejected, .noRecentSuccess] {
            #expect(statusIconState(health: .healthy, status: Self.status([.idle], alerts: [alert])) == .warning, "\(alert)")
        }
    }

    /// Never green over a failure (anti-goal 3): the failure alerts are errors.
    @Test func errorForAFailureAlert() {
        for alert in [AlertCondition.backupFailed, .checkFailed, .fullDiskAccessMissing, .configurationError] {
            #expect(statusIconState(health: .healthy, status: Self.status([.idle], alerts: [alert])) == .error, "\(alert)")
        }
    }

    @Test func errorWinsOverWarning() {
        let status = Self.status([.skipped(.noNetwork), .stopped(reason: "x")], alerts: [.noRecentSuccess])
        #expect(statusIconState(health: .healthy, status: status) == .error)
    }

    /// While checking or updating, the status is from before the change and isn't judged.
    @Test func neutralWhileTransitioning() {
        let broken = Self.status([.stopped(reason: "x")], configError: "corrupt")
        for state in [AgentHealthState.checking, .updating, .waitingForUpdate] {
            #expect(statusIconState(health: state, status: broken) == .neutral, "\(state)")
        }
    }
}
