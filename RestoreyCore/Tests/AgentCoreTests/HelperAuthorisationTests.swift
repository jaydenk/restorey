import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The launch-chain check (spec §7, "Confused deputy"): a helper call is honoured only when the
/// caller's parent is, right now, a restic the agent is supervising for the plan named in the request.
struct HelperAuthorisationTests {
    private static let caller: pid_t = 4242
    private static let restic: pid_t = 4243
    private static let resticStart = KernelProcessInfo.StartTime(seconds: 1_800_000_000, microseconds: 1234)

    /// The caller's parent is `parent`; `parent` started at `parentStart`. Every other pid is unknown.
    private static func lookup(
        parent: pid_t? = restic, parentStart: KernelProcessInfo.StartTime = resticStart
    ) -> (pid_t) -> KernelProcessInfo? {
        { pid in
            if pid == caller, let parent {
                return KernelProcessInfo(parentPID: parent, startTime: .init(seconds: 1_800_000_100, microseconds: 0))
            }
            if pid == parent { return KernelProcessInfo(parentPID: 1, startTime: parentStart) }
            return nil
        }
    }

    private static func supervising(_ pid: pid_t = restic, plan: UUID, start: KernelProcessInfo.StartTime = resticStart)
        async -> SupervisedProcesses
    {
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: pid, planID: plan, startTime: start)
        return supervised
    }

    @Test func parentIsSupervisedResticForPlan() async {
        let plan = UUID()
        #expect(await authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(), supervised: await Self.supervising(plan: plan)))
    }

    @Test func parentSupervisedForOtherPlanRefused() async {
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: UUID(), lookup: Self.lookup(),
            supervised: await Self.supervising(plan: UUID())))
    }

    @Test func unsupervisedParentRefused() async {
        let plan = UUID()
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(),
            supervised: await Self.supervising(9999, plan: plan)))
    }

    @Test func unknownParentRefused() async {
        let plan = UUID()
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(parent: nil),
            supervised: await Self.supervising(plan: plan)))
    }

    /// The parent pid is known but the parent itself has gone: no start time to compare, so refused.
    @Test func parentThatNoLongerExistsRefused() async {
        let plan = UUID()
        let lookup: (pid_t) -> KernelProcessInfo? = { pid in
            pid == Self.caller ? KernelProcessInfo(parentPID: Self.restic, startTime: Self.resticStart) : nil
        }
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: lookup, supervised: await Self.supervising(plan: plan)))
    }

    /// A process that reused a supervised restic's pid has a different start time: refused.
    @Test func samePIDWithADifferentStartTimeRefused() async {
        let plan = UUID()
        let later = KernelProcessInfo.StartTime(seconds: Self.resticStart.seconds + 5, microseconds: 0)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(parentStart: later),
            supervised: await Self.supervising(plan: plan)))
        let sameSecond = KernelProcessInfo.StartTime(seconds: Self.resticStart.seconds, microseconds: 999)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(parentStart: sameSecond),
            supervised: await Self.supervising(plan: plan)))
    }

    /// The caller must be restic's child, not restic itself: restic never asks the agent directly.
    @Test func supervisedCallerWithUnsupervisedParentRefused() async {
        let plan = UUID()
        let supervised = await Self.supervising(Self.caller, plan: plan, start: .init(seconds: 1_800_000_100, microseconds: 0))
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(), supervised: supervised))
    }

    /// Once restic has exited and been removed, its pid is no longer trusted.
    @Test func parentNoLongerSupervisedRefused() async {
        let plan = UUID()
        let supervised = await Self.supervising(plan: plan)
        await supervised.remove(pid: Self.restic)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, lookup: Self.lookup(), supervised: supervised))
    }

    // MARK: Kernel process info

    @Test func processInfoOfThisProcessHasGetppidAndAStableStartTime() throws {
        let first = try #require(processInfo(pid: getpid()))
        #expect(first.parentPID == getppid())
        #expect(first.startTime.seconds > 0)
        #expect(processInfo(pid: getpid())?.startTime == first.startTime)
    }

    @Test func processInfoOfAnExitedProcessIsNil() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        // Reaped by waitUntilExit, so the pid names no process (barring immediate reuse).
        #expect(processInfo(pid: process.processIdentifier) == nil)
    }
}
