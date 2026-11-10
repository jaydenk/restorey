import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The launch-chain check (spec §7, "Confused deputy"): a helper call is honoured only when the
/// caller's parent is a restic the agent is supervising for the plan named in the request.
struct HelperAuthorisationTests {
    private static let caller: pid_t = 4242
    private static let restic: pid_t = 4243

    private static func parent(_ parent: pid_t?) -> (pid_t) -> pid_t? {
        { pid in pid == caller ? parent : nil }
    }

    @Test func parentIsSupervisedResticForPlan() async {
        let plan = UUID()
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: Self.restic, planID: plan)
        #expect(await authoriseHelper(
            callerPID: Self.caller, planID: plan, parentOf: Self.parent(Self.restic), supervised: supervised))
    }

    @Test func parentSupervisedForOtherPlanRefused() async {
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: Self.restic, planID: UUID())
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: UUID(), parentOf: Self.parent(Self.restic), supervised: supervised))
    }

    @Test func unsupervisedParentRefused() async {
        let plan = UUID()
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: 9999, planID: plan)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, parentOf: Self.parent(Self.restic), supervised: supervised))
    }

    @Test func unknownParentRefused() async {
        let plan = UUID()
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: Self.restic, planID: plan)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, parentOf: Self.parent(nil), supervised: supervised))
    }

    /// The caller must be restic's child, not restic itself: restic never asks the agent directly.
    @Test func supervisedCallerWithUnsupervisedParentRefused() async {
        let plan = UUID()
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: Self.caller, planID: plan)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, parentOf: Self.parent(Self.restic), supervised: supervised))
    }

    /// Once restic has exited and been removed, its pid is no longer trusted (pid reuse).
    @Test func parentNoLongerSupervisedRefused() async {
        let plan = UUID()
        let supervised = SupervisedProcesses()
        await supervised.insert(pid: Self.restic, planID: plan)
        await supervised.remove(pid: Self.restic)
        #expect(await !authoriseHelper(
            callerPID: Self.caller, planID: plan, parentOf: Self.parent(Self.restic), supervised: supervised))
    }

    // MARK: Parent pid lookup

    @Test func parentPIDOfThisProcessIsGetppid() {
        #expect(parentPID(of: getpid()) == getppid())
    }

    @Test func parentPIDOfAnExitedProcessIsNil() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        // Reaped by waitUntilExit, so the pid names no process (barring immediate reuse).
        #expect(parentPID(of: process.processIdentifier) == nil)
    }
}
