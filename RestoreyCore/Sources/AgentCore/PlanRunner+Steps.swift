import Foundation
import RestoreyCore

/// Winding down (Ruling R55) and running one restic step.
extension PlanRunner {
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
        progress: Bool = false, collector: LineCollector? = nil, recorded: Bool = true
    ) async -> StepResult {
        let plan = session.plan
        let id = UUID()
        let startedAt = deps.now()
        var writer: RunLogWriter?
        // `recorded` false (a credential check): no run log and no in-progress marker, since no record follows.
        if recorded {
            do {
                writer = try await deps.logStore.begin(
                    planID: plan.id, operation: op, startedAt: startedAt, redactor: session.redactor)
            } catch {
                logger.error("Couldn't create the \(op.logSlug, privacy: .public) run log: \(error.localizedDescription, privacy: .public)")
            }
        }
        let log = StepLog(writer: writer)
        let logFile = writer.map { "runs/\(plan.id.uuidString)/\($0.fileURL.lastPathComponent)" } ?? ""

        if recorded {
            let provisional = RunRecord(
                id: id, planID: plan.id, operation: op, trigger: trigger, startedAt: startedAt, endedAt: startedAt,
                outcome: .interrupted, summary: nil, logFile: logFile)
            await write(plan.id) { history in
                history.runningRecord = provisional
                history.runningRecordID = id
                if op == .backup {
                    history.attemptBeforeRun = history.lastAttemptAt
                    Self.noteAttempt(at: startedAt, in: &history)
                }
            }
        }

        var context = session.context
        if op == .backup { context.repositoryLinkTarget = await repositoryLinkTarget(plan) }
        let uploadsToTheNetwork = op == .backup && plan.repository.needsNetwork
        if uploadsToTheNetwork {
            context.macWideUploadLimitKiB = await deps.state.networkSettings.uploadLimitKiB
            // Counted and registered with no suspension in between, so backups starting together each see
            // the others. restic can't change its limit mid-run, so each keeps the share it started with.
            context.networkedBackupsRunning = networkedUploads.count + 1
            networkedUploads.insert(id)
        }
        let invocation = makeInvocation(op, plan: plan, context: context)
        log.line("Restorey \(op.logSlug) for \(plan.name), \(trigger.rawValue)")
        log.line(displayCommand(invocation))
        let process = ResticProcess(
            executable: deps.resticExecutable, invocation: invocation, planID: plan.id,
            supervisor: deps.supervisor, homeDirectory: deps.homeDirectory)
        if let intent = handle?.attach(process) {
            await process.interrupt(intent, killAfter: deps.interruptGracePeriod)
        }
        let feed = progress ? ProgressFeed(state: deps.state, planID: plan.id, redactor: session.redactor) : nil
        let additions = op == .backup ? BiggestAdditionsCollector(sources: plan.sources) : nil

        var outcome: RunOutcome
        var termination: ResticTermination?
        deps.sleepPrevention?.begin()
        do {
            defer { deps.sleepPrevention?.end() }
            let finished = try await process.run { message in
                for text in StepLog.lines(for: message, operation: op) { log.line(text) }
                feed?.send(message)
                collector?.collect(message)
                additions?.collect(message)
            }
            termination = finished
            // A restic that exits 130 with no request from us, while the system is stopping the agent,
            // was signalled by the system itself before our SIGINT went out: the same system stop.
            var intent = finished.interruptIntent
            if intent == nil, await deps.state.isStoppingForSystem { intent = .systemStop }
            outcome = classify(
                operation: op, exitCode: finished.exitCode, interruptedByUs: intent,
                terminatedBySignal: finished.terminatedBySignal, killedByUs: finished.killedByUs,
                summary: finished.summary, errors: finished.messages,
                droppedArchivalErrors: finished.droppedArchivalErrorCount, exitErrorMessage: finished.exitErrorMessage)
            if finished.terminatedBySignal != nil { needsUnlock.insert(session.key) }
        } catch {
            outcome = .failed(
                exitCode: Self.startFailureExitCode, reason: "Restorey couldn’t start restic: \(error.localizedDescription)")
        }
        handle?.detach()
        // restic has exited (or never started): it no longer takes a share of the limit.
        networkedUploads.remove(id)
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
        let biggestAdditions = Self.biggestAdditions(op, outcome, additions)
        if additions != nil, Self.madeSnapshot(outcome) {
            log.line(BiggestAdditionsText.logLine(biggestAdditions))
            if let shortfall = BiggestAdditionsText.shortfallLogLine(
                biggestAdditions, dataAddedPacked: termination?.summary?.dataAddedPacked)
            {
                log.line(shortfall)
            }
        }
        log.line("Finished: \(Self.explain(outcome, stoppedReason: stoppedReason))")
        log.close()

        let record = RunRecord(
            id: id, planID: plan.id, operation: op, trigger: trigger, startedAt: startedAt, endedAt: deps.now(),
            outcome: outcome, summary: op == .backup ? termination?.summary : nil, logFile: logFile,
            droppedLogLines: log.droppedLineCount,
            unreadableItems: Self.unreadableItems(op, outcome, termination), biggestAdditions: biggestAdditions)
        var tail = termination?.stderrTail ?? []
        if let helperFailure { tail.append(helperFailure) }
        return StepResult(record: record, stoppedReason: stoppedReason, tail: tail)
    }

    /// The files a backup couldn't read, for its record (Task 16b): only a backup that ended as a warning has any.
    static func unreadableItems(_ op: ResticOperation, _ outcome: RunOutcome, _ termination: ResticTermination?) -> [UnreadableItem]? {
        guard case .backup = op, case .warning = outcome, let termination else { return nil }
        return UnreadableItems.collect(termination.messages)
    }

    /// What a backup added, biggest first, for its record (Task 16d): only a backup that made a snapshot (`success` with
    /// one, or `warning`) has any, and only when restic printed its verbose lines.
    static func biggestAdditions(
        _ op: ResticOperation, _ outcome: RunOutcome, _ collector: BiggestAdditionsCollector?
    ) -> BiggestAdditions? {
        guard case .backup = op, madeSnapshot(outcome), let collector else { return nil }
        return collector.result()
    }

    /// restic finished the backup with a snapshot.
    private static func madeSnapshot(_ outcome: RunOutcome) -> Bool {
        switch outcome {
        case .success(snapshotID: .some), .warning: true
        default: false
        }
    }
}
