import Foundation
import os
import RestoreyCore

/// Runs a plan end to end. A backup goes:
///
/// 1. refusals that need no restic: an invalid plan (Ruling R7) or an unconfirmed recovery kit;
/// 2. `preflight`;
/// 3. the Full Disk Access probe (missing: a failure and the `fullDiskAccessMissing` alert, no restic);
/// 4. the repository's queue; in its slot, a plain `unlock` first if a restic died there by a signal;
/// 5. the items apps mark as not for backup, looked for (bounded, off the cooperative pool) when the plan skips them,
///    and passed to restic in a file of their own, removed when restic has finished (Task 15c);
/// 6. the backup, classified (there is no check-in `/start` ping, Ruling R57);
/// 7. history and alerts (written after every step, so an agent that dies mid-run loses nothing);
/// 8. the check-in end ping, as soon as the backup's record is committed (Ruling R37);
/// 9. in the same queue slot, after a successful backup: setup's confirmed removal of earlier snapshots
///    when one is waiting (PlanRunner+EarlierSnapshots.swift), then `forget`, `prune` (then `stats`, for the
///    repository size, when it succeeded) and a plain `unlock` followed by `check`, when each is due
///    (`maintenance`).
///
/// No restic step starts while the agent is winding down (`isWindingDown`: draining, or its executable
/// replaced), because restic would run the replaced helper, which this agent refuses (Ruling R55). The
/// step in flight finishes. A backup that hadn't started is recorded `.skipped(.agentUpdating)` with no
/// ping, and the next agent runs it at once; maintenance not yet started waits for the next backup.
/// The check is a best-effort guard: a drain or replacement that lands between the check and restic's
/// launch still lets that one step start.
///
/// A failure found before the backup starts (an invalid plan, a missing source, Full Disk Access
/// missing, unreadable backup keys) sends `/fail` with the reason (Ruling R33). A skip, a pause, and a
/// plan whose recovery kit isn't confirmed yet send nothing.
///
/// Every restic step has its own `RunRecord` and run log. A maintenance failure is its own record and
/// alert and never turns the backup's record into a failure. Wrong password, missing repository and
/// unreadable credentials stop the plan (`stoppedReason`) until a later backup succeeds or the plan's
/// repository or secrets are changed.
///
/// Pings go out in order per plan but without holding up the run, because the sender retries for
/// minutes when the check-in service is down; `pingsFlushed()` waits for them.
///
/// Runs asked for while `recoverAfterStart()` is in progress wait for it to finish.
public actor PlanRunner {
    static let fullDiskAccessMissing = "Full Disk Access is missing"
    static let keychainUnreadable = "Couldn’t read the backup keys from the Keychain"
    /// The exit code of a run that restic never ran for (refused, or restic couldn't start).
    static let startFailureExitCode: Int32 = RunOutcome.notStartedExitCode
    static let day: TimeInterval = 86_400
    static let week: TimeInterval = 7 * 86_400

    let deps: RunnerDependencies
    let logger: Logger
    /// Runs in flight, by plan.
    var handles: [UUID: RunHandle] = [:]
    /// Marked items already logged as backed up because restic can't be given their names exactly: each is logged once.
    var loggedUnrepresentable: Set<String> = []
    /// Set once a backup has logged that an earlier Spotlight look is still outstanding; cleared by the next look that
    /// runs, so a stuck episode is logged once.
    var loggedStuckLook = false
    /// One cloud-only walk at a time (task 18 fix round 1): an `fts` walk stuck in a File Provider call can't be
    /// stopped, so without it every backup would leave one more blocked thread behind.
    nonisolated let cloudOnlyWalkGate = OneOutstandingGate()
    /// Set once a backup has logged that an earlier cloud-only walk is still stuck; cleared by the next walk that runs.
    var loggedStuckWalk = false
    /// Set once a backup has logged that the repository's link check got no answer (timed out, or an earlier one is
    /// stuck); cleared by the next check that does answer, so one stuck episode logs one line, not one per backup.
    var loggedStuckLinkCheck = false
    /// The latest background run `backUpNow` started, by plan.
    var background: [UUID: Task<RunRecord, Never>] = [:]
    /// Plans to back up (trigger `.manual`) as soon as their run, being paused, has ended: a Resume that
    /// came while that run was still stopping (Ruling R62).
    var startWhenPausedRunEnds: Set<UUID> = []
    /// The last ping queued, by plan; the next one waits for it.
    var pingTails: [UUID: Task<Void, Never>] = [:]
    /// Repositories where a restic died by a signal (our SIGKILL, a crash), so its lock may be left
    /// behind: the next run there starts with a plain `unlock`. An honoured SIGINT removes restic's own
    /// lock (docs/spike-findings.md), so a clean pause doesn't land here.
    var needsUnlock: Set<String> = []
    /// `recoverAfterStart`, while it runs and after: runs wait for it.
    var recovery: Task<Void, Never>?
    /// The backup steps to networked repositories whose restic is uploading now, by record ID: they share
    /// the Mac-wide upload limit (Ruling P2-7).
    var networkedUploads: Set<UUID> = []
    /// When `pruneRunLogsIfDue` last pruned the run logs; nil until it has (Ruling R70).
    var lastRunLogPrune: Date?
    /// The measurements queued after an adopt (PlanRunner+Actions.swift), credential checks and recovery's
    /// unlocks, waiting or running, by plan, so a pause, a delete and a system stop reach them as they reach runs.
    var measurementHandles: [UUID: [RunHandle]] = [:]
    /// The latest measurement queued after an adopt, by plan, for `waitForMeasurement`.
    var measurements: [UUID: Task<Void, Never>] = [:]

    public init(dependencies: RunnerDependencies) {
        deps = dependencies
        logger = Logger(subsystem: dependencies.logSubsystem, category: "runner")
    }

    // MARK: Public API

    /// Runs one backup now and returns its record. Throws only when the run can't be registered:
    /// draining, the config-error state, an unknown plan, a plan being deleted or already running.
    public func runBackup(planID: UUID, trigger: RunTrigger) async throws -> RunRecord {
        let handle = try await begin(planID, isBackup: true)
        let record = await backup(planID: planID, trigger: trigger, handle: handle)
        await end(planID, handle)
        return record
    }

    /// Starts a manual backup of one plan (or of every plan that may run, when nil) in the background
    /// and returns the status showing it running. A single plan that is invalid or has no confirmed
    /// recovery kit is refused with the reason; one already running is reported as such, not refused.
    ///
    /// `afterPausedRun` is Resume's (Ruling R62): when the plan's run is still stopping (for a pause, or a Cancel
    /// that a pause followed), the backup starts, through this same path, once that run has ended, instead of
    /// being refused as "already backing up". Back Up Now itself doesn't pass it.
    public func backUpNow(_ planID: UUID?, afterPausedRun: Bool = false) async throws -> BackUpNowReply {
        try await deps.state.requireRunnable(planID)
        var alreadyRunning = false
        if let planID {
            let plan = try await deps.state.runInputs(planID).plan
            if let refusal = Self.refusal(plan) { throw refusal }
            if afterPausedRun, handles[planID]?.intent != nil {
                startWhenPausedRunEnds.insert(planID)
            } else {
                // A backup step already under way and carrying on (the scheduler got there first) is the backup
                // asked for. Anything else holding the plan (a run stopping for a pause, a run's maintenance after
                // its backup step, an adopt) is refused as before; only Resume queues a backup behind a stopping
                // run (Ruling R62).
                if handles[planID]?.isLiveBackup == true {
                    alreadyRunning = true
                } else {
                    try await startInBackground(planID)
                }
            }
        } else {
            for (plan, _) in await deps.state.allRunInputs() where Self.refusal(plan) == nil {
                // Plans already running are left to finish; the rest start. Anything else that stops one
                // starting is written to agent.log, since this call still succeeds for the others.
                do {
                    try await startInBackground(plan.id)
                } catch AgentError.alreadyRunning {
                    continue
                } catch {
                    let message = (error as? AgentError)?.message ?? "\(error)"
                    deps.agentLog("Back Up Now couldn't start plan \(plan.id.uuidString): \(message)")
                }
            }
        }
        return BackUpNowReply(status: await deps.state.status(), alreadyRunning: alreadyRunning)
    }

    /// Setup's Start (Task 9): confirms the kit the person saved (`kitDigest`, checked by the state) and starts the
    /// plan's first backup, a manual one, in the background. The run's handle is registered first, as `begin` does, so a
    /// pause or Cancel reaches it from the moment the plan shows confirmed; the state then saves the confirmation and
    /// registers the run in one step (`AgentState.confirmKit`). Any refusal confirms nothing and starts nothing.
    func startFirstBackup(planID: UUID, kitDigest: String?) async throws -> AgentStatus {
        await recovery?.value
        try await deps.state.requireRunnable(planID)
        if handles[planID] != nil {
            let name = (try? await deps.state.runInputs(planID).plan.name) ?? "This plan"
            throw AgentError.alreadyRunning(name: name)
        }
        let handle = RunHandle(isBackup: true)
        handles[planID] = handle
        let confirmed: (status: AgentStatus, began: Bool)
        do {
            confirmed = try await deps.state.confirmKit(planID, kitDigest: kitDigest, beginningRun: true)
        } catch {
            if handles[planID] === handle { handles[planID] = nil }
            throw error
        }
        guard confirmed.began else {
            if handles[planID] === handle { handles[planID] = nil }
            return confirmed.status
        }
        background[planID] = Task {
            let record = await backup(planID: planID, trigger: .manual, handle: handle)
            await end(planID, handle)
            return record
        }
        return confirmed.status
    }

    /// On agent start, before the runner is attached to the state: turns every run still marked in
    /// progress into an `.interrupted` record (an interrupted backup also sends its `/fail` ping), then
    /// runs a plain `unlock` once per repository, through its queue (Review Focus 3). Calling it again
    /// waits for the first call.
    ///
    /// Repositories of plans that may run (valid, recovery kit confirmed) and of any plan that had an
    /// interrupted run are unlocked. A plain unlock removes only stale locks, never another client's
    /// live one. An unlock that can't run is logged in the agent log.
    public func recoverAfterStart() async {
        if let recovery { return await recovery.value }
        let task = Task { await recover() }
        recovery = task
        await task.value
    }

    /// Waits until every ping queued so far, for every plan, has been handed to the sender.
    public func pingsFlushed() async {
        for tail in pingTails.values { await tail.value }
    }

}
