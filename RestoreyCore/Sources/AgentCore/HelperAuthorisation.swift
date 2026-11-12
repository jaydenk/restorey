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
/// **Fail-closed timing.** `ResticProcess` records restic in `SupervisedProcesses` one actor hop after
/// `process.run()`. A helper call that restic makes before that insertion lands is refused, never
/// granted: the window can only cost a failed run (restic reports it and the agent retries), it can
/// never hand a secret to an unsupervised process. restic runs its password command and the S3 chain
/// after start-up, so in practice the insertion wins.
///
/// **Recycled pids.** The parent is matched by pid *and* kernel start time, so a process that reuses a
/// supervised restic's pid after it exits never matches. `ResticProcess` also drops restic as soon as
/// its termination arrives.
///
/// Residual risk, stated in the README: code that can hijack a restic Restorey is supervising can
/// obtain that plan's secrets.
///
/// - Parameters:
///   - lookup: the kernel's view of a pid (parent and start time), or nil if it has none.
///     `processInfo(pid:)` in the agent.
/// - Returns: true only when the caller's parent is, right now, the same restic supervised for
///   exactly `planID`.
public func authoriseHelper(
    callerPID: pid_t, planID: UUID, lookup: (pid_t) -> KernelProcessInfo?, supervised: SupervisedProcesses
) async -> Bool {
    guard let caller = lookup(callerPID), caller.parentPID > 0,
          let parent = lookup(caller.parentPID)
    else { return false }
    return await supervised.isSupervised(pid: caller.parentPID, planID: planID, startTime: parent.startTime)
}
