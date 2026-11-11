import Foundation
import os
import RestoreyCore

/// Everything `PlanRunner` works with. The probe, the environment and the check-in sender are
/// injected so tests can drive them; the agent passes the real ones.
public struct RunnerDependencies: Sendable {
    public var state: AgentState
    public var secrets: any SecretStore
    public var queues: RepositoryQueues
    public var supervisor: SupervisedProcesses
    public var logStore: RunLogStore
    public var checkIn: any CheckInSending
    public var resticExecutable: URL
    /// The agent's own executable, resolved: restic runs it for the password and S3 credentials.
    public var helperExecutable: URL
    /// `<Caches>/<id root>/restic`, passed as `--cache-dir`.
    public var cacheDirectory: URL
    /// Where `CredentialsFile` writes each S3 plan's `s3/<id>.ini`.
    public var credentialsDirectory: URL
    /// restic's `HOME`.
    public var homeDirectory: URL
    /// The `os_log` subsystem for the runner's own problems (`Identity.rootID`).
    public var logSubsystem: String
    public var fdaProbe: @Sendable () -> FDAProbeResult
    public var preflightEnvironment: @Sendable () async -> PreflightEnvironment
    public var now: @Sendable () -> Date
    /// How long restic gets to honour SIGINT before SIGKILL (global constraints: 10 s).
    public var interruptGracePeriod: Duration
    /// Held while each restic step runs, so the Mac doesn't idle-sleep mid-run (spec §8). Nil: none.
    public var sleepPrevention: SleepPrevention?
    /// Writes a line to the agent's own log (`agent.log`), for problems the user may need to find.
    public var agentLog: @Sendable (String) -> Void
    /// True once the agent's executable on disk is no longer the one it was started from (an update
    /// replaced the bundle). Checked before every restic step and on every scheduler tick (Ruling R55).
    public var binaryReplaced: @Sendable () -> Bool

    public init(
        state: AgentState, secrets: any SecretStore, queues: RepositoryQueues, supervisor: SupervisedProcesses,
        logStore: RunLogStore, checkIn: any CheckInSending, resticExecutable: URL, helperExecutable: URL,
        cacheDirectory: URL, credentialsDirectory: URL, homeDirectory: URL, logSubsystem: String,
        fdaProbe: @escaping @Sendable () -> FDAProbeResult,
        preflightEnvironment: @escaping @Sendable () async -> PreflightEnvironment,
        now: @escaping @Sendable () -> Date,
        interruptGracePeriod: Duration = .seconds(10),
        sleepPrevention: SleepPrevention? = nil,
        agentLog: @escaping @Sendable (String) -> Void = { _ in },
        binaryReplaced: @escaping @Sendable () -> Bool = { false }
    ) {
        self.state = state
        self.secrets = secrets
        self.queues = queues
        self.supervisor = supervisor
        self.logStore = logStore
        self.checkIn = checkIn
        self.resticExecutable = resticExecutable
        self.helperExecutable = helperExecutable
        self.cacheDirectory = cacheDirectory
        self.credentialsDirectory = credentialsDirectory
        self.homeDirectory = homeDirectory
        self.logSubsystem = logSubsystem
        self.fdaProbe = fdaProbe
        self.preflightEnvironment = preflightEnvironment
        self.now = now
        self.interruptGracePeriod = interruptGracePeriod
        self.sleepPrevention = sleepPrevention
        self.agentLog = agentLog
        self.binaryReplaced = binaryReplaced
    }
}

/// Runs a plan end to end. A backup goes:
///
/// 1. refusals that need no restic: an invalid plan (Ruling R7) or an unconfirmed recovery kit;
/// 2. `preflight`;
/// 3. the Full Disk Access probe (missing: a failure and the `fullDiskAccessMissing` alert, no restic);
/// 4. the repository's queue; in its slot, a plain `unlock` first if a restic died there by a signal;
/// 5. the backup, classified (there is no check-in `/start` ping, Ruling R57);
/// 6. history and alerts (written after every step, so an agent that dies mid-run loses nothing);
/// 7. the check-in end ping, as soon as the backup's record is committed (Ruling R37);
/// 8. in the same queue slot, after a successful backup: `forget`, `prune` and a plain `unlock`
///    followed by `check`, when each is due (`maintenance`).
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
    static let keychainUnreadable = "Couldn't read the backup keys from the Keychain"
    /// The exit code of a run that restic never ran for (refused, or restic couldn't start).
    static let startFailureExitCode: Int32 = -1
    static let day: TimeInterval = 86_400
    static let week: TimeInterval = 7 * 86_400

    let deps: RunnerDependencies
    let logger: Logger
    /// Runs in flight, by plan.
    private var handles: [UUID: RunHandle] = [:]
    /// The latest background run `backUpNow` started, by plan.
    private var background: [UUID: Task<RunRecord, Never>] = [:]
    /// Plans to back up (trigger `.manual`) as soon as their run, being paused, has ended: a Resume that
    /// came while that run was still stopping (Ruling R62).
    private var startWhenPausedRunEnds: Set<UUID> = []
    /// The last ping queued, by plan; the next one waits for it.
    private var pingTails: [UUID: Task<Void, Never>] = [:]
    /// Repositories where a restic died by a signal (our SIGKILL, a crash), so its lock may be left
    /// behind: the next run there starts with a plain `unlock`. An honoured SIGINT removes restic's own
    /// lock (docs/spike-findings.md), so a clean pause doesn't land here.
    private var needsUnlock: Set<String> = []
    /// `recoverAfterStart`, while it runs and after: runs wait for it.
    private var recovery: Task<Void, Never>?

    public init(dependencies: RunnerDependencies) {
        deps = dependencies
        logger = Logger(subsystem: dependencies.logSubsystem, category: "runner")
    }

    // MARK: Public API

    /// Runs one backup now and returns its record. Throws only when the run can't be registered:
    /// draining, the config-error state, an unknown plan, a plan being deleted or already running.
    public func runBackup(planID: UUID, trigger: RunTrigger) async throws -> RunRecord {
        let handle = try await begin(planID)
        let record = await backup(planID: planID, trigger: trigger, handle: handle)
        await end(planID, handle)
        return record
    }

    /// Starts a manual backup of one plan (or of every plan that may run, when nil) in the background
    /// and returns the status showing it running. A single plan that is invalid or has no confirmed
    /// recovery kit is refused with the reason.
    ///
    /// `afterPausedRun` is Resume's (Ruling R62): when the plan's run is still stopping for a pause, the
    /// backup starts, through this same path, once that run has ended and recorded `.paused`, instead of
    /// being refused as "already backing up". Back Up Now itself doesn't pass it.
    public func backUpNow(_ planID: UUID?, afterPausedRun: Bool = false) async throws -> AgentStatus {
        try await deps.state.requireRunnable(planID)
        if let planID {
            let plan = try await deps.state.runInputs(planID).plan
            if let refusal = Self.refusal(plan) { throw refusal }
            if afterPausedRun, handles[planID]?.intent == .pause {
                startWhenPausedRunEnds.insert(planID)
            } else {
                try await startInBackground(planID)
            }
        } else {
            for (plan, _) in await deps.state.allRunInputs() where Self.refusal(plan) == nil {
                // Plans already running are left to finish; the rest start.
                try? await startInBackground(plan.id)
            }
        }
        return await deps.state.status()
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

    // MARK: Recovery

    private func recover() async {
        let entries = await deps.state.allRunInputs()
        let now = deps.now()
        var interrupted: Set<UUID> = []
        for (plan, history) in entries where history.runningRecordID != nil || history.runningRecord != nil {
            var record = history.runningRecord ?? RunRecord(
                id: history.runningRecordID ?? UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
                startedAt: history.lastAttemptAt ?? now, endedAt: now, outcome: .interrupted, summary: nil,
                logFile: "")
            record.endedAt = now
            record.outcome = .interrupted
            await commit(record, plan: plan)
            interrupted.insert(plan.id)
            if record.operation == .backup,
                let ping = pingAtEnd(outcome: .interrupted, logTail: [], redactor: redactor(for: plan))
            {
                queuePing(ping, planID: plan.id)
            }
        }

        var unlocked: Set<String> = []
        for (plan, _) in entries
        where plan.validationErrors().isEmpty && (plan.recoveryKitConfirmedAt != nil || interrupted.contains(plan.id)) {
            let key = RepositoryQueues.key(for: plan.repository)
            guard !unlocked.contains(key) else { continue }
            let handle: RunHandle
            do {
                handle = try await begin(plan.id, waitForRecovery: false)
            } catch {
                skippedUnlock(plan, reason: (error as? AgentError)?.message ?? "\(error)")
                continue
            }
            switch prepare(plan) {
            case .ready(let session):
                unlocked.insert(key)
                let step = await deps.queues.run(repository: key) { [self] () async -> StepResult? in
                    guard !(await isWindingDown()) else { return nil }
                    return await runStep(.unlock, trigger: .scheduled, session: session, handle: handle)
                }
                if let step {
                    await commit(step.record, plan: plan)
                } else {
                    skippedUnlock(plan, reason: AgentError.draining.message)
                }
            case .failed(_, let reason, _):
                skippedUnlock(plan, reason: reason)
            }
            await end(plan.id, handle)
        }
    }

    private func skippedUnlock(_ plan: Plan, reason: String) {
        deps.agentLog(
            "Recovery skipped the unlock for plan \(plan.id.uuidString), so a stale lock may remain until its next backup: \(reason)")
    }

    // MARK: Interrupts and background runs

    /// Asks the plan's run in progress, if any, to stop. A request repeated while it is pending is
    /// ignored. `AgentState.pause` is the one way in.
    func interrupt(planID: UUID, intent: InterruptIntent) async {
        guard let process = handles[planID]?.request(intent) else { return }
        await process.interrupt(intent, killAfter: deps.interruptGracePeriod)
    }

    /// Waits for the latest run `backUpNow` started for the plan and returns its record.
    func waitForBackgroundRun(planID: UUID) async -> RunRecord? {
        await background[planID]?.value
    }

    private func startInBackground(_ planID: UUID) async throws {
        let handle = try await begin(planID)
        background[planID] = Task {
            let record = await backup(planID: planID, trigger: .manual, handle: handle)
            await end(planID, handle)
            return record
        }
    }

    /// Waits for recovery (unless this is recovery), then registers the run with `AgentState` (which
    /// refuses while draining, for an unknown plan, a plan being deleted or already running) and gives it
    /// a handle `pause` can reach from that moment on.
    func begin(_ planID: UUID, waitForRecovery: Bool = true) async throws -> RunHandle {
        if waitForRecovery { await recovery?.value }
        try await deps.state.requireRunnable(planID)
        if handles[planID] != nil {
            let name = (try? await deps.state.runInputs(planID).plan.name) ?? "This plan"
            throw AgentError.alreadyRunning(name: name)
        }
        let handle = RunHandle()
        handles[planID] = handle
        do {
            try await deps.state.beginRun(planID: planID)
        } catch {
            if handles[planID] === handle { handles[planID] = nil }
            throw error
        }
        return handle
    }

    func end(_ planID: UUID, _ handle: RunHandle) async {
        if handles[planID] === handle { handles[planID] = nil }
        await deps.state.endRun(planID: planID)
        guard startWhenPausedRunEnds.remove(planID) != nil else { return }
        // Paused again meanwhile: the new pause wins, and its end is the scheduler's catch-up.
        if let until = try? await deps.state.runInputs(planID).history.pausedUntil, until > deps.now() { return }
        do {
            try await startInBackground(planID)
        } catch {
            let message = (error as? AgentError)?.message ?? "\(error)"
            deps.agentLog("Couldn't start the backup Resume asked for, for plan \(planID.uuidString): \(message)")
        }
    }

    // MARK: Backup

    private func backup(planID: UUID, trigger: RunTrigger, handle: RunHandle) async -> RunRecord {
        let startedAt = deps.now()
        guard let plan = try? await deps.state.runInputs(planID).plan else {
            // Unreachable: a plan can't be deleted while it runs. Not recorded: there is no history.
            return RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: startedAt,
                outcome: .failed(exitCode: Self.startFailureExitCode, reason: AgentError.unknownPlan.message),
                summary: nil, logFile: "")
        }
        /// Records a run that never reached restic. A failure (`failPing`) sends `/fail` with its reason.
        func refuse(_ outcome: RunOutcome, fda: FDAProbeResult? = nil, failPing: Bool = false) async -> RunRecord {
            let record = RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: deps.now(), outcome: outcome, summary: nil, logFile: "")
            await commit(record, plan: plan, fda: fda)
            if failPing, case .failed(_, let reason) = outcome,
                let ping = pingAtEnd(outcome: outcome, logTail: [reason], redactor: redactor(for: plan))
            {
                queuePing(ping, planID: planID)
            }
            return record
        }
        func failed(_ reason: String) -> RunOutcome { .failed(exitCode: Self.startFailureExitCode, reason: reason) }

        switch Self.refusal(plan) {
        case .invalidPlan(let errors)?:
            return await refuse(failed(AgentError.invalidPlan(errors).message), failPing: true)
        case let refusal?:
            // No recovery kit yet: the plan isn't set up, so the check-in isn't told anything.
            return await refuse(failed(refusal.message))
        case nil:
            break
        }
        switch preflight(plan: plan, env: await deps.preflightEnvironment()) {
        case .skip(let reason): return await refuse(.skipped(reason))
        case .fail(let message): return await refuse(failed(message), failPing: true)
        case .run: break
        }
        let fda = deps.fdaProbe()
        await deps.state.noteFullDiskAccess(fda)
        if fda == .missing { return await refuse(failed(Self.fullDiskAccessMissing), fda: fda, failPing: true) }
        if let intent = handle.intent { return await refuse(intent == .pause ? .paused : .cancelled, fda: fda) }

        switch prepare(plan) {
        case .failed(let outcome, let reason, let redactor):
            let record = RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: deps.now(), outcome: outcome, summary: nil, logFile: "")
            await commit(record, plan: plan, fda: fda, stoppedReason: reason)
            queueEndPing(StepResult(record: record, stoppedReason: reason, tail: [reason]), redactor: redactor)
            return record
        case .ready(let session):
            return await deps.queues.run(repository: session.key) { [self] in
                await backupSlot(session: session, trigger: trigger, handle: handle, fda: fda, startedAt: startedAt)
            }.record
        }
    }

    /// The backup's success or `/fail` ping (none for a pause, cancel or lock).
    private func queueEndPing(_ result: StepResult, redactor: Redactor) {
        if let ping = pingAtEnd(outcome: result.record.outcome, logTail: result.tail, redactor: redactor) {
            queuePing(ping, planID: result.record.planID)
        }
    }

    /// The backup and its maintenance, in one turn of the repository's queue. The backup's end ping is
    /// queued as soon as its record is committed, before any maintenance (Ruling R37): it reports the
    /// backup, and a slow or failing check must neither delay nor change it. Before each step, an agent
    /// winding down stops (Ruling R55): before the backup, it records it `.skipped(.agentUpdating)`.
    private func backupSlot(
        session: RunSession, trigger: RunTrigger, handle: RunHandle, fda: FDAProbeResult, startedAt: Date
    ) async -> StepResult {
        let plan = session.plan
        func skippedForUpdate() async -> StepResult {
            let record = RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: deps.now(), outcome: .skipped(.agentUpdating), summary: nil, logFile: "")
            await commit(record, plan: plan, fda: fda)
            return StepResult(record: record, stoppedReason: nil, tail: [])
        }
        if needsUnlock.contains(session.key) {
            if await isWindingDown() { return await skippedForUpdate() }
            let unlock = await runStep(.unlock, trigger: trigger, session: session, handle: handle)
            await commit(unlock.record, plan: plan)
        }

        if await isWindingDown() { return await skippedForUpdate() }
        let backup = await runStep(.backup, trigger: trigger, session: session, handle: handle, progress: true)
        await commit(backup.record, plan: plan, fda: fda, stoppedReason: backup.stoppedReason)
        queueEndPing(backup, redactor: session.redactor)

        guard handle.intent == nil, let history = try? await deps.state.runInputs(plan.id).history else {
            return backup
        }
        for op in Self.maintenance(plan: plan, history: history, after: backup.record.outcome, now: deps.now()) {
            // Not started while winding down: the next agent runs it at its next backup.
            guard handle.intent == nil, !(await isWindingDown()) else { break }
            let step = await runStep(op, trigger: trigger, session: session, handle: handle)
            await commit(step.record, plan: plan)
            switch step.record.outcome {
            case .paused, .cancelled, .locked:
                // Interrupted, or another client holds the lock: try the rest at the next backup.
                return backup
            default:
                continue
            }
        }
        return backup
    }

    // MARK: Winding down (Ruling R55)

    /// True when no new restic step may start: the agent is draining (the app asked, before an update or
    /// a re-registration), or its executable has been replaced, which begins a restart drain now. A
    /// restic started by a replaced agent runs the new helper, which this agent's XPC listener refuses
    /// (its signature seals an Info.plist no longer on disk), so the step would fail at the password.
    public func isWindingDown() async -> Bool {
        if await deps.state.isDraining { return true }
        guard deps.binaryReplaced() else { return false }
        await deps.state.restartForReplacedBinary()
        return true
    }

    // MARK: Steps

    struct StepResult: Sendable {
        var record: RunRecord
        /// Set for the outcomes that stop the plan.
        var stoppedReason: String?
        /// The last lines restic wrote to stderr, for a `/fail` ping.
        var tail: [String]
    }

    /// Runs one restic command with its own log and record. While it runs, history marks it in progress
    /// (`runningRecord`), so an agent that dies mid-step leaves an `.interrupted` record on recovery.
    func runStep(
        _ op: ResticOperation, trigger: RunTrigger, session: RunSession, handle: RunHandle?,
        progress: Bool = false, collector: LineCollector? = nil
    ) async -> StepResult {
        let plan = session.plan
        let id = UUID()
        let startedAt = deps.now()
        var writer: RunLogWriter?
        do {
            writer = try await deps.logStore.begin(
                planID: plan.id, operation: op, startedAt: startedAt, redactor: session.redactor)
        } catch {
            logger.error("Couldn't create the \(op.logSlug, privacy: .public) run log: \(error.localizedDescription, privacy: .public)")
        }
        let log = StepLog(writer: writer)
        let logFile = writer.map { "runs/\(plan.id.uuidString)/\($0.fileURL.lastPathComponent)" } ?? ""

        let provisional = RunRecord(
            id: id, planID: plan.id, operation: op, trigger: trigger, startedAt: startedAt, endedAt: startedAt,
            outcome: .interrupted, summary: nil, logFile: logFile)
        await write(plan.id) { history in
            history.runningRecord = provisional
            history.runningRecordID = id
            if op == .backup { Self.noteAttempt(at: startedAt, in: &history) }
        }

        let invocation = makeInvocation(op, plan: plan, context: session.context)
        log.line("Restorey \(op.logSlug) for \(plan.name), \(trigger.rawValue)")
        log.line(displayCommand(invocation))
        let process = ResticProcess(
            executable: deps.resticExecutable, invocation: invocation, planID: plan.id,
            supervisor: deps.supervisor, homeDirectory: deps.homeDirectory)
        if let intent = handle?.attach(process) {
            await process.interrupt(intent, killAfter: deps.interruptGracePeriod)
        }
        let feed = progress ? ProgressFeed(state: deps.state, planID: plan.id, redactor: session.redactor) : nil

        var outcome: RunOutcome
        var termination: ResticTermination?
        deps.sleepPrevention?.begin()
        do {
            defer { deps.sleepPrevention?.end() }
            let finished = try await process.run { message in
                if let text = StepLog.text(for: message) { log.line(text) }
                feed?.send(message)
                collector?.collect(message)
            }
            termination = finished
            outcome = classify(
                operation: op, exitCode: finished.exitCode, interruptedByUs: finished.interruptIntent,
                terminatedBySignal: finished.terminatedBySignal, killedByUs: finished.killedByUs,
                summary: finished.summary, errors: finished.messages, exitErrorMessage: finished.exitErrorMessage)
            if finished.terminatedBySignal != nil { needsUnlock.insert(session.key) }
        } catch {
            outcome = .failed(
                exitCode: Self.startFailureExitCode, reason: "Restorey couldn't start restic: \(error.localizedDescription)")
        }
        handle?.detach()
        await feed?.finish()
        if op == .unlock, outcome == .success(snapshotID: nil) { needsUnlock.remove(session.key) }

        // The helper's own reason for a keychain failure: restic only says "no credentials found", or
        // fails some other way (an empty password). Either way the backup keys couldn't be read, which
        // won't fix itself in an hour: it is the credentials stop.
        let helperFailure = await deps.state.takeHelperFailure(planID: plan.id)
        if helperFailure != nil, case .failed = outcome { outcome = .credentialsUnavailable }
        if case .failed(let code, let reason) = outcome {
            outcome = .failed(exitCode: code, reason: session.redactor.redact(reason))
        }
        let stoppedReason = Self.stoppedReason(for: outcome, helperFailure: helperFailure)
        log.line("Finished: \(Self.explain(outcome, stoppedReason: stoppedReason))")
        log.close()

        let record = RunRecord(
            id: id, planID: plan.id, operation: op, trigger: trigger, startedAt: startedAt, endedAt: deps.now(),
            outcome: outcome, summary: op == .backup ? termination?.summary : nil, logFile: logFile,
            droppedLogLines: log.droppedLineCount)
        var tail = termination?.stderrTail ?? []
        if let helperFailure { tail.append(helperFailure) }
        return StepResult(record: record, stoppedReason: stoppedReason, tail: tail)
    }

    // MARK: History and alerts

    /// Adds `record` to the plan's history with everything it implies, and refreshes the alerts. The
    /// in-progress marker is cleared only when it is this record's, so recovery's `.interrupted` record
    /// for an old run can never wipe the marker of a run that has started since.
    /// - Parameters:
    ///   - fda: the probe result this run saw, which raises or clears `fullDiskAccessMissing`.
    ///   - stoppedReason: set for a backup that stops the plan.
    func commit(
        _ record: RunRecord, plan: Plan, fda: FDAProbeResult? = nil, stoppedReason: String? = nil
    ) async {
        let now = deps.now()
        await write(plan.id) { history in
            if history.runningRecord?.id == record.id
                || (history.runningRecord == nil && history.runningRecordID == record.id)
            {
                history.runningRecordID = nil
                history.runningRecord = nil
            }
            history.record(record)
            Self.apply(record, stoppedReason: stoppedReason, to: &history)
            switch fda {
            case .missing?:
                if history.activeAlerts[.fullDiskAccessMissing] == nil {
                    history.activeAlerts[.fullDiskAccessMissing] = AlertNotificationState(
                        raisedAt: now, lastNotifiedAt: nil, count: 0)
                }
            case .granted?: history.activeAlerts[.fullDiskAccessMissing] = nil
            case .cannotVerify?, nil: break
            }
            Self.refreshAlerts(&history, plan: plan, now: now)
        }
    }

    private func write(_ planID: UUID, _ change: @escaping @Sendable (inout PlanRunHistory) -> Void) async {
        do {
            try await deps.state.updateHistory(planID, change)
        } catch {
            // The run itself is unaffected, but its record is lost: say so where it can be found.
            let message = (error as? AgentError)?.message ?? "\(error)"
            logger.error("Couldn't save the run history: \(message, privacy: .public)")
            deps.agentLog("Couldn't save the run history for plan \(planID.uuidString): \(message)")
        }
    }

    private func queuePing(_ ping: CheckInPing, planID: UUID) {
        let previous = pingTails[planID]
        let checkIn = deps.checkIn
        pingTails[planID] = Task {
            await previous?.value
            await checkIn.send(ping, planID: planID)
        }
    }
}
