import Darwin
import Foundation
import RestoreyCore

/// The launch-chain check behind the password and S3 credential helper (spec §7, "(spike, decided)
/// Confused deputy"; docs/spike-findings.md H2).
///
/// The agent's own executable is restic's `RESTIC_PASSWORD_COMMAND` and its `credential_process`.
/// Run by hand, that correctly signed binary would hand any same-user process every secret. So the
/// helper holds no secrets: it asks the running agent over XPC, and the agent decides here. The XPC
/// listener has already checked the caller's audit token against the agent's own code requirement, so
/// `callerPID` is our signed helper. This then requires the helper's parent to be a restic the agent
/// itself spawned and is still supervising, for the plan the request names. The helper cannot make
/// this check itself: a child can't get its parent's audit token, and a pid-and-path check is fooled by
/// fork-then-exec of the signed binary.
///
/// **Fail-closed timing.** `ResticProcess` inserts restic's pid into `SupervisedProcesses` one actor
/// hop after `process.run()`. A helper call that restic makes before that insertion lands is refused,
/// never granted: the window can only cost a failed run (restic reports it and the agent retries), it
/// can never hand a secret to an unsupervised process. restic runs its password command and the S3
/// chain after start-up, so in practice the insertion wins.
///
/// Residual risk, stated in the README: code that can hijack a restic Restorey is supervising can
/// obtain that plan's secrets.
///
/// - Parameters:
///   - parentOf: the caller's parent pid, or nil if it can't be read. `parentPID(of:)` in the agent.
/// - Returns: true only when the caller's parent is supervised for exactly `planID`.
public func authoriseHelper(
    callerPID: pid_t, planID: UUID, parentOf: (pid_t) -> pid_t?, supervised: SupervisedProcesses
) async -> Bool {
    guard let parent = parentOf(callerPID), parent > 0 else { return false }
    return await supervised.isSupervised(pid: parent, planID: planID)
}

/// The parent pid of `pid` from `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`'s `kp_eproc.e_ppid`,
/// or nil when no such process exists or the call fails.
public func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = mib.withUnsafeMutableBufferPointer { mib in
        sysctl(mib.baseAddress, u_int(mib.count), &info, &size, nil, 0)
    }
    // A pid with no process succeeds with size 0.
    guard result == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
    return info.kp_eproc.e_ppid
}
