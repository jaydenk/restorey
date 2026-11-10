import Foundation

/// The restic processes the agent started and is still waiting on, with the plan each belongs to.
///
/// The password helper (Task 13) asks `isSupervised(pid:planID:)` before it prints a repository
/// password: a request is honoured only when it comes from a process the agent itself launched for
/// that plan. `ResticProcess` inserts the pid before it reads the first line of output and removes
/// it once the process has exited and its output has been read, so a recycled pid is never trusted.
public actor SupervisedProcesses {
    /// The agent's shared registry. Tests use their own instances.
    public static let shared = SupervisedProcesses()

    private var plans: [pid_t: UUID] = [:]

    public init() {}

    public func insert(pid: pid_t, planID: UUID) {
        plans[pid] = planID
    }

    public func remove(pid: pid_t) {
        plans[pid] = nil
    }

    /// True only when `pid` is supervised for exactly this plan.
    public func isSupervised(pid: pid_t, planID: UUID) -> Bool {
        plans[pid] == planID
    }

    public func all() -> [pid_t] {
        plans.keys.sorted()
    }
}
