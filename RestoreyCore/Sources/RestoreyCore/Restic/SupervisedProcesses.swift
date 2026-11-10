import Foundation

/// The restic processes the agent started and is still supervising, with the plan each belongs to.
///
/// The password and S3 credential helper (`authoriseHelper`, AgentCore) is answered only when its
/// parent is one of these, for the plan it names. Each entry is bound to the process's kernel start
/// time as well as its pid, so a later process that reuses the pid never matches: a recycled pid is
/// never trusted. `ResticProcess` inserts restic just after spawning it (only once it has confirmed
/// that pid is its own live child) and removes it as soon as restic's termination arrives, without
/// waiting for its output pipes to drain (a grandchild holding stdout open can keep those open long
/// after restic itself is gone).
public actor SupervisedProcesses {
    /// The agent's shared registry. Tests use their own instances.
    public static let shared = SupervisedProcesses()

    private struct Entry {
        let planID: UUID
        let startTime: KernelProcessInfo.StartTime
    }

    private var entries: [pid_t: Entry] = [:]

    public init() {}

    public func insert(pid: pid_t, planID: UUID, startTime: KernelProcessInfo.StartTime) {
        entries[pid] = Entry(planID: planID, startTime: startTime)
    }

    public func remove(pid: pid_t) {
        entries[pid] = nil
    }

    /// True only when `pid` is supervised for exactly this plan and `startTime` is the recorded one,
    /// i.e. it is still the same process.
    public func isSupervised(pid: pid_t, planID: UUID, startTime: KernelProcessInfo.StartTime) -> Bool {
        guard let entry = entries[pid] else { return false }
        return entry.planID == planID && entry.startTime == startTime
    }

    public func all() -> [pid_t] {
        entries.keys.sorted()
    }
}
