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

    public init(
        state: AgentState, secrets: any SecretStore, queues: RepositoryQueues, supervisor: SupervisedProcesses,
        logStore: RunLogStore, checkIn: any CheckInSending, resticExecutable: URL, helperExecutable: URL,
        cacheDirectory: URL, credentialsDirectory: URL, homeDirectory: URL, logSubsystem: String,
        fdaProbe: @escaping @Sendable () -> FDAProbeResult,
        preflightEnvironment: @escaping @Sendable () async -> PreflightEnvironment,
        now: @escaping @Sendable () -> Date,
        interruptGracePeriod: Duration = .seconds(10)
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
    }
}

/// Runs a plan end to end. A backup goes:
///
/// 1. refusals that need no restic: an invalid plan (Ruling R7) or an unconfirmed recovery kit;
/// 2. `preflight` (a skip or a failure here sends no ping, spec §6.2);
/// 3. the Full Disk Access probe (missing: a failure and the `fullDiskAccessMissing` alert, no restic);
/// 4. the check-in `/start` ping;
/// 5. the backup, through the repository's queue, then classified;
/// 6. in the same queue slot, after a successful backup: `forget`, `prune` and a plain `unlock`
///    followed by `check`, when each is due (`maintenance`);
/// 7. history and alerts (written after every step, so an agent that dies mid-run loses nothing);
/// 8. the check-in end ping.
///
/// Every restic step has its own `RunRecord` and run log. A maintenance failure is its own record and
/// alert and never turns the backup's record into a failure. Wrong password, missing repository and
/// unreadable credentials stop the plan (`stoppedReason`) until a later backup succeeds.
///
/// Pings go out in order per plan but without holding up the run, because the sender retries for
/// minutes when the check-in service is down.
public actor PlanRunner {
    static let fullDiskAccessMissing = "Full Disk Access is missing"
    static let keychainUnreadable = "Couldn't read the backup keys from the Keychain"
    static let day: TimeInterval = 86_400
    static let week: TimeInterval = 7 * 86_400

    private let deps: RunnerDependencies
    private let logger: Logger
    /// Runs in flight, by plan.
    private var handles: [UUID: RunHandle] = [:]
    /// The latest background run `backUpNow` started, by plan.
    private var background: [UUID: Task<RunRecord, Never>] = [:]
    /// The last ping queued, by plan; the next one waits for it.
    private var pingTails: [UUID: Task<Void, Never>] = [:]
    /// Repositories where a restic died by a signal (our SIGKILL, a crash), so its lock may be left
    /// behind: the next run there starts with a plain `unlock`. An honoured SIGINT removes restic's own
    /// lock (docs/spike-findings.md), so a clean pause doesn't land here.
    private var needsUnlock: Set<String> = []

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
    public func backUpNow(_ planID: UUID?) async throws -> AgentStatus {
        try await deps.state.requireRunnable(planID)
        if let planID {
            let plan = try await deps.state.runInputs(planID).plan
            if let refusal = Self.refusal(plan) { throw refusal }
            try await startInBackground(planID)
        } else {
            for (plan, _) in await deps.state.allRunInputs() where Self.refusal(plan) == nil {
                // Plans already running are left to finish; the rest start.
                try? await startInBackground(plan.id)
            }
        }
        return await deps.state.status()
    }

    /// Pauses for an hour and interrupts a run in progress, which then ends `.paused`. Allowed while
    /// draining (Ruling R27).
    public func pause(planID: UUID) async throws -> AgentStatus {
        let status = try await deps.state.pause(planID)
        await interrupt(planID: planID, intent: .pause)
        return status
    }

    /// Runs `restic init`. Never called on its own: only this explicit action creates a repository.
    public func createRepository(planID: UUID) async throws -> AgentStatus {
        let handle = try await begin(planID)
        let result = await initialise(planID: planID, handle: handle)
        await end(planID, handle)
        try result.get()
        return await deps.state.status()
    }

    /// Lists the repository's snapshots for every host. Never forgets or changes anything.
    public func adopt(planID: UUID) async throws -> AdoptReport {
        let handle = try await begin(planID)
        let result = await listForAdoption(planID: planID, handle: handle)
        await end(planID, handle)
        return try result.get()
    }

    /// On agent start: turns every run still marked in progress into an `.interrupted` record, then runs
    /// a plain `unlock` once per repository, through its queue (Review Focus 3).
    ///
    /// Repositories of plans that may run (valid, recovery kit confirmed) and of any plan that had an
    /// interrupted run are unlocked. A plain unlock removes only stale locks, never another client's
    /// live one.
    public func recoverAfterStart() async {
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
        }

        var unlocked: Set<String> = []
        for (plan, _) in entries
        where plan.validationErrors().isEmpty && (plan.recoveryKitConfirmedAt != nil || interrupted.contains(plan.id)) {
            let key = RepositoryQueues.key(for: plan.repository)
            guard !unlocked.contains(key), let handle = try? await begin(plan.id) else { continue }
            unlocked.insert(key)
            if case .ready(let session) = prepare(plan) {
                let step = await deps.queues.run(repository: key) { [self] in
                    await runStep(.unlock, trigger: .scheduled, session: session, handle: handle)
                }
                await commit(step.record, plan: plan)
            }
            await end(plan.id, handle)
        }
    }

    // MARK: Interrupts and background runs

    /// Asks the plan's run in progress, if any, to stop. A request repeated while it is pending is ignored.
    func interrupt(planID: UUID, intent: InterruptIntent) async {
        guard let process = handles[planID]?.request(intent) else { return }
        await process.interrupt(intent, killAfter: deps.interruptGracePeriod)
    }

    /// Waits for the latest run `backUpNow` started for the plan and returns its record.
    func waitForBackgroundRun(planID: UUID) async -> RunRecord? {
        await background[planID]?.value
    }

    /// Waits until every ping queued so far for the plan has been handed to the sender.
    func pingsDelivered(planID: UUID) async {
        await pingTails[planID]?.value
    }

    private func startInBackground(_ planID: UUID) async throws {
        let handle = try await begin(planID)
        background[planID] = Task {
            let record = await backup(planID: planID, trigger: .manual, handle: handle)
            await end(planID, handle)
            return record
        }
    }

    /// Registers the run with `AgentState` (which refuses while draining, for an unknown plan, a plan
    /// being deleted or already running) and gives it a handle `pause` can reach from that moment on.
    private func begin(_ planID: UUID) async throws -> RunHandle {
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

    private func end(_ planID: UUID, _ handle: RunHandle) async {
        if handles[planID] === handle { handles[planID] = nil }
        await deps.state.endRun(planID: planID)
    }

    // MARK: Backup

    private func backup(planID: UUID, trigger: RunTrigger, handle: RunHandle) async -> RunRecord {
        let startedAt = deps.now()
        guard let plan = try? await deps.state.runInputs(planID).plan else {
            // Unreachable: a plan can't be deleted while it runs. Not recorded: there is no history.
            return RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: startedAt, outcome: .failed(exitCode: -1, reason: AgentError.unknownPlan.message),
                summary: nil, logFile: "")
        }
        func refuse(_ outcome: RunOutcome, fda: FDAProbeResult? = nil) async -> RunRecord {
            let record = RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: deps.now(), outcome: outcome, summary: nil, logFile: "")
            await commit(record, plan: plan, fda: fda)
            return record
        }

        // Before restic, and before any ping.
        if let refusal = Self.refusal(plan) { return await refuse(.failed(exitCode: -1, reason: refusal.message)) }
        switch preflight(plan: plan, env: await deps.preflightEnvironment()) {
        case .skip(let reason): return await refuse(.skipped(reason))
        case .fail(let message): return await refuse(.failed(exitCode: -1, reason: message))
        case .run: break
        }
        let fda = deps.fdaProbe()
        await deps.state.noteFullDiskAccess(fda)
        if fda == .missing {
            return await refuse(.failed(exitCode: -1, reason: Self.fullDiskAccessMissing), fda: fda)
        }
        if let intent = handle.intent { return await refuse(intent == .pause ? .paused : .cancelled, fda: fda) }

        for ping in pingsAtStart(trigger: trigger) { queuePing(ping, planID: planID) }

        let result: StepResult
        let redactor: Redactor
        switch prepare(plan) {
        case .failed(let outcome, let reason, let partialRedactor):
            redactor = partialRedactor
            let record = RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: deps.now(), outcome: outcome, summary: nil, logFile: "")
            await commit(record, plan: plan, fda: fda, stoppedReason: reason)
            result = StepResult(record: record, stoppedReason: reason, tail: [reason])
        case .ready(let session):
            redactor = session.redactor
            result = await deps.queues.run(repository: session.key) { [self] in
                await backupSlot(session: session, trigger: trigger, handle: handle, fda: fda)
            }
        }

        if let ping = pingAtEnd(outcome: result.record.outcome, logTail: result.tail, redactor: redactor) {
            queuePing(ping, planID: planID)
        }
        return result.record
    }

    /// The backup and its maintenance, in one turn of the repository's queue.
    private func backupSlot(
        session: RunSession, trigger: RunTrigger, handle: RunHandle, fda: FDAProbeResult
    ) async -> StepResult {
        let plan = session.plan
        if needsUnlock.contains(session.key) {
            let unlock = await runStep(.unlock, trigger: trigger, session: session, handle: handle)
            await commit(unlock.record, plan: plan)
        }

        let backup = await runStep(.backup, trigger: trigger, session: session, handle: handle, progress: true)
        await commit(backup.record, plan: plan, fda: fda, stoppedReason: backup.stoppedReason)

        guard handle.intent == nil, let history = try? await deps.state.runInputs(plan.id).history else {
            return backup
        }
        for op in Self.maintenance(plan: plan, history: history, after: backup.record.outcome, now: deps.now()) {
            guard handle.intent == nil else { break }
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

    // MARK: Create and adopt

    private func initialise(planID: UUID, handle: RunHandle) async -> Result<Void, AgentError> {
        let step: StepResult
        switch await actionStep(.initRepository, planID: planID, handle: handle) {
        case .failure(let error): return .failure(error)
        case .success(let result): step = result
        }
        switch step.record.outcome {
        case .success:
            return .success(())
        case .failed(_, let reason) where reason.localizedCaseInsensitiveContains("already exists"):
            return .failure(.repositoryAlreadyExists)
        case let outcome:
            return .failure(.operationFailed(
                "Restorey couldn't create the repository: \(Self.explain(outcome, stoppedReason: step.stoppedReason))"))
        }
    }

    private func listForAdoption(planID: UUID, handle: RunHandle) async -> Result<AdoptReport, AgentError> {
        let collector = LineCollector(matching: SnapshotListing.isListing)
        let step: StepResult
        switch await actionStep(.snapshots(allHosts: true), planID: planID, handle: handle, collector: collector) {
        case .failure(let error): return .failure(error)
        case .success(let result): step = result
        }
        guard case .success = step.record.outcome else {
            return .failure(.operationFailed(Self.explain(step.record.outcome, stoppedReason: step.stoppedReason)))
        }
        let plan = (try? await deps.state.runInputs(planID).plan)
        do {
            return .success(try SnapshotListing.report(from: collector.last ?? "[]", hostLabel: plan?.hostLabel ?? ""))
        } catch {
            return .failure(.operationFailed("Restorey couldn't read restic's list of snapshots"))
        }
    }

    /// One restic step the app asked for (init, adopt): no preflight, no probe, no pings, no maintenance.
    private func actionStep(
        _ op: ResticOperation, planID: UUID, handle: RunHandle, collector: LineCollector? = nil
    ) async -> Result<StepResult, AgentError> {
        guard let plan = try? await deps.state.runInputs(planID).plan else { return .failure(.unknownPlan) }
        let errors = plan.validationErrors()
        guard errors.isEmpty else { return .failure(.invalidPlan(errors)) }
        let session: RunSession
        switch prepare(plan) {
        case .ready(let ready): session = ready
        case .failed(_, let reason, _): return .failure(.operationFailed(reason))
        }
        let step = await deps.queues.run(repository: session.key) { [self] in
            await runStep(op, trigger: .manual, session: session, handle: handle, collector: collector)
        }
        await commit(step.record, plan: plan)
        return .success(step)
    }

    // MARK: Steps

    /// What a step needs that comes from the plan and the keychain.
    struct RunSession: Sendable {
        let plan: Plan
        let context: ResticContext
        let redactor: Redactor
        /// `RepositoryQueues.key(for:)` of the plan's repository.
        let key: String
    }

    enum Preparation: Sendable {
        case ready(RunSession)
        /// Restic can't be run. `redactor` holds whatever secrets could be read, for the ping.
        case failed(RunOutcome, reason: String, redactor: Redactor)
    }

    struct StepResult: Sendable {
        var record: RunRecord
        /// Set for the outcomes that stop the plan.
        var stoppedReason: String?
        /// The last lines restic wrote to stderr, for a `/fail` ping.
        var tail: [String]
    }

    /// Reads the plan's secrets for the redactor (and a raw plan's environment), and writes an S3 plan's
    /// credentials file with the agent as the helper. Only the raw environment is required here: the
    /// password and S3 keys are fetched by restic through the helper, which reports its own failures.
    private func prepare(_ plan: Plan) -> Preparation {
        var known: [String] = []
        for key in [SecretKey.repositoryPassword(plan.id), .s3AccessKeyID(plan.id), .s3SecretAccessKey(plan.id)] {
            if let value = try? deps.secrets.read(key) { known.append(value) }
        }
        let checkInURL = (try? deps.secrets.read(.checkInURL(plan.id))) ?? nil

        var environment: [String: String] = [:]
        var problems: [String] = []
        if case .raw(_, let names) = plan.repository {
            for name in names {
                do {
                    if let value = try deps.secrets.read(.environment(plan.id, name: name)) {
                        environment[name] = value
                        known.append(value)
                    } else {
                        problems.append("The environment value \(name) isn't in the Keychain")
                    }
                } catch {
                    problems.append("Restorey couldn't read the environment value \(name): \(error)")
                }
            }
        }
        let redactor = Redactor(secrets: known, checkInURLs: checkInURL.map { [$0] } ?? [])
        if !problems.isEmpty {
            let reason = ([Self.keychainUnreadable] + problems).joined(separator: ". ")
            return .failed(.credentialsUnavailable, reason: reason, redactor: redactor)
        }

        var credentialsFile: URL?
        if case .s3 = plan.repository {
            do {
                credentialsFile = try CredentialsFile.write(
                    planID: plan.id, helper: deps.helperExecutable, directory: deps.credentialsDirectory)
            } catch {
                let reason = "Restorey couldn't write the S3 credentials file: \(error)"
                return .failed(.failed(exitCode: -1, reason: reason), reason: reason, redactor: redactor)
            }
        }
        let context = ResticContext(
            cacheDirectory: deps.cacheDirectory, helperExecutable: deps.helperExecutable,
            credentialsFile: credentialsFile, rawEnvironment: environment, homeDirectory: deps.homeDirectory)
        return .ready(RunSession(
            plan: plan, context: context, redactor: redactor, key: RepositoryQueues.key(for: plan.repository)))
    }

    /// Runs one restic command with its own log and record. While it runs, history marks it in progress
    /// (`runningRecord`), so an agent that dies mid-step leaves an `.interrupted` record on recovery.
    private func runStep(
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
        do {
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
            outcome = .failed(exitCode: -1, reason: "Restorey couldn't start restic: \(error.localizedDescription)")
        }
        handle?.detach()
        await feed?.finish()
        if op == .unlock, outcome == .success(snapshotID: nil) { needsUnlock.remove(session.key) }

        // The helper's own reason for a keychain failure: restic only says "no credentials found".
        let helperFailure = await deps.state.takeHelperFailure(planID: plan.id)
        if case .failed(let code, let reason) = outcome {
            outcome = .failed(exitCode: code, reason: session.redactor.redact(Self.joined(reason, helperFailure)))
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

    /// Adds `record` to the plan's history with everything it implies, and refreshes the alerts.
    /// - Parameters:
    ///   - fda: the probe result this run saw, which raises or clears `fullDiskAccessMissing`.
    ///   - stoppedReason: set for a backup that stops the plan.
    private func commit(
        _ record: RunRecord, plan: Plan, fda: FDAProbeResult? = nil, stoppedReason: String? = nil
    ) async {
        let now = deps.now()
        await write(plan.id) { history in
            if history.runningRecordID == record.id || history.runningRecord?.id == record.id
                || record.outcome == .interrupted
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
            // The run itself is unaffected; its record is lost, so say so where it can be found.
            logger.error("Couldn't save the run history: \((error as? AgentError)?.message ?? "\(error)", privacy: .public)")
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
