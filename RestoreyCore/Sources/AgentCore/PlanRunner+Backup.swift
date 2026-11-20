import Foundation
import RestoreyCore

/// One plan's backup, from its pre-run checks to its maintenance.
extension PlanRunner {
    // MARK: Backup

    func backup(planID: UUID, trigger: RunTrigger, handle: RunHandle) async -> RunRecord {
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
        var environment = await deps.preflightEnvironment()
        environment.networkSettings = await deps.state.networkSettings
        switch preflight(plan: plan, env: environment) {
        case .skip(let reason): return await refuse(.skipped(reason))
        case .fail(let message): return await refuse(failed(message), failPing: true)
        case .run: break
        }
        let fda = deps.fdaProbe()
        await deps.state.noteFullDiskAccess(fda)
        if fda == .missing { return await refuse(failed(Self.fullDiskAccessMissing), fda: fda, failPing: true) }
        if let intent = handle.intent { return await refuse(intent.outcome, fda: fda) }

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
        /// A backup that never started because the agent is winding down: stopped by the system when
        /// that is why (Ruling R67), otherwise skipped for the update.
        func skippedForUpdate() async -> StepResult {
            let outcome: RunOutcome = handle.intent == .systemStop ? .stoppedBySystem : .skipped(.agentUpdating)
            let record = RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: trigger, startedAt: startedAt,
                endedAt: deps.now(), outcome: outcome, summary: nil, logFile: "")
            await commit(record, plan: plan, fda: fda)
            return StepResult(record: record, stoppedReason: nil, tail: [])
        }
        if needsUnlock.contains(session.key) {
            if await isWindingDown() { return await skippedForUpdate() }
            let unlock = await runStep(.unlock, trigger: trigger, session: session, handle: handle)
            await commit(unlock.record, plan: plan)
        }

        // Looked for first, so the check for winding down still comes right before restic starts.
        let marked = await notForBackupList(plan: plan)
        if await isWindingDown() {
            removeNotForBackupList(marked.file)
            return await skippedForUpdate()
        }
        var backupSession = session
        backupSession.context.notForBackupExcludeFile = marked.file
        var backup = await runStep(.backup, trigger: trigger, session: backupSession, handle: handle, progress: true)
        // restic has exited (or never started), however the step ended: success, failure, a cancel, a pause or the
        // system stopping the agent (which waits for the run to end before it exits).
        removeNotForBackupList(marked.file)
        handle.backupStepEnded()
        if Self.savedData(backup.record.outcome) { backup.record.markedNotForBackupSkipped = marked.count }
        backup.record.cloudOnlySkipped = await countCloudOnly(after: backup.record, plan: plan)
        // Read before this record replaces it as the plan's last backup.
        let previousBackup = try? await deps.state.runInputs(plan.id).history.lastBackupRecord
        await commit(backup.record, plan: plan, fda: fda, stoppedReason: backup.stoppedReason)
        queueEndPing(backup, redactor: session.redactor)

        guard handle.intent == nil, let history = try? await deps.state.runInputs(plan.id).history else {
            return backup
        }
        // Setup's confirmed removal of the snapshots from before adoption waits for a backup that succeeded (Task 14b):
        // `.success` or `.unchanged`, not a `.warning` that left files out, which would take the newest retention
        // buckets in their timeline. It comes first, so a prune due now frees their space. Stopped (a lock held
        // elsewhere, an interruption, an update) it and the maintenance wait for the next backup; a preview that failed
        // leaves the choice for the next backup but the maintenance goes on (final review I2).
        if let pending = history.pendingEarlierRemoval, Self.succeededFully(backup.record.outcome), !(await isWindingDown()),
            !(await runPendingEarlierRemoval(pending, session: session, handle: handle, trigger: trigger))
        {
            return backup
        }
        // A backup that couldn't read many more files than the last holds back the tidy it would have followed with
        // (and the prune after it). The skip is its own record, so the History list and the Overview can say why.
        let heldBack = Self.forgetHeldBack(after: backup.record.outcome, previousBackup: previousBackup)
        if let reason = heldBack,
            Self.maintenance(plan: plan, history: history, after: backup.record.outcome, now: deps.now())
                .contains(.forget(dryRun: false))
        {
            let at = deps.now()
            await commit(
                RunRecord(
                    id: UUID(), planID: plan.id, operation: .forget(dryRun: false), trigger: trigger, startedAt: at,
                    endedAt: at, outcome: .skipped(reason), summary: nil, logFile: ""),
                plan: plan)
        }
        for op in Self.maintenance(
            plan: plan, history: history, after: backup.record.outcome, now: deps.now(), forgetHeld: heldBack != nil)
        {
            // Not started while winding down: the next agent runs it at its next backup.
            guard handle.intent == nil, !(await isWindingDown()) else { break }
            let step = await runStep(op, trigger: trigger, session: session, handle: handle)
            await commit(step.record, plan: plan)
            var outcome = step.record.outcome
            // The size changes mostly when a prune frees space, so it is measured then (Ruling P2-9).
            if op == .prune, case .success = outcome, handle.intent == nil, !(await isWindingDown()) {
                outcome = await measureRepository(session: session, trigger: trigger, handle: handle)
            }
            switch outcome {
            case .paused, .cancelled, .locked, .stoppedBySystem:
                // Interrupted, or another client holds the lock: try the rest at the next backup.
                return backup
            default:
                continue
            }
        }
        return backup
    }

    /// The cloud-only files `--exclude-cloud-files` skipped, counted after a backup restic finished with a snapshot
    /// (`success` with a snapshot, or `warning`; `unchanged` made none but the files are still skipped). Information
    /// only: nil for any other run, and when the count gives up, which is logged at INFO. It runs on a background
    /// thread and is bounded, so it never blocks or fails the run (Task 15b).
    ///
    /// One walk at a time (`cloudOnlyWalkGate`): a count that finds another plan's walk running waits for it within
    /// its own deadline, and one that finds a walk still stuck past its deadline doesn't walk at all (nil, logged once
    /// per episode), so a wedged File Provider holds one thread, not one per backup.
    private func countCloudOnly(after record: RunRecord, plan: Plan) async -> CloudOnlyCount? {
        guard Self.savedData(record.outcome) else { return nil }
        let count = deps.cloudOnlySkipped
        let (sources, exclusions) = (plan.sources, plan.exclusions)
        let end = ContinuousClock.now.advanced(by: .seconds(deps.cloudOnlyDeadline))
        let gate = cloudOnlyWalkGate
        guard await gate.enter(until: end) else {
            if !loggedStuckWalk {
                loggedStuckWalk = true
                deps.agentInfo(
                    "Not counting cloud-only files for plan \(plan.id.uuidString): an earlier count is still waiting "
                        + "for the file system to answer")
            }
            return nil
        }
        loggedStuckWalk = false
        let remaining = max(0, ContinuousClock.now.duration(to: end) / .seconds(1))
        // On a thread of its own, neither a Swift concurrency one nor a GCD global queue's (task 18): the walk blocks in
        // system calls, and a deadline on a global queue waited for a free thread. The first of the walk and the
        // deadline decides; a walk that finishes later is ignored and touches nothing but its own locals.
        let result: CloudOnlyCounter.Result? = await OwnThread.run(
            named: "Restorey cloud-only count", qualityOfService: .utility, deadline: remaining, orElse: .gaveUp
        ) {
            let result = count(sources, exclusions)
            // Only when the walk has really returned: a walk abandoned at the deadline keeps the gate until then.
            gate.leave()
            return result
        }
        switch result {
        case .counted(let counted): return counted
        case .gaveUp:
            deps.agentInfo("Gave up counting cloud-only files for plan \(plan.id.uuidString): too many files or too slow")
            return nil
        case nil: return nil
        }
    }

    /// True for a backup restic finished with a snapshot (`success` with one, or `warning`), or found unchanged (no
    /// snapshot, but its exclusions applied all the same): the runs whose skipped-item counts are recorded.
    static func savedData(_ outcome: RunOutcome) -> Bool {
        switch outcome {
        case .success(snapshotID: .some), .unchanged, .warning: true
        default: false
        }
    }

    /// The items apps mark as not for backup that this backup skips (Task 15c), written for restic's `--exclude-file`,
    /// and how many: the plan's sources looked up in Spotlight on a thread of its own within the bound
    /// (`MarkedItemsScan.offPool`: 10 seconds, 100,000 results), each still carrying the attribute, collapsed for the
    /// plan (`MarkedNotForBackup.collapse`). Never fails or delays the backup beyond the bound: nil file and count when
    /// the plan doesn't skip them, there is no finder, the look gives up (logged at INFO) or the file can't be written
    /// (logged at ERROR), so the items are backed up, the safe direction. No file, and a count of 0, when none are found.
    private func notForBackupList(plan: Plan) async -> (file: URL?, count: Int?) {
        guard plan.skipsItemsMarkedNotForBackup, let finder = deps.markedItems else { return (nil, nil) }
        let id = plan.id.uuidString
        let verified: [String]
        let result = await MarkedItemsScan.offPool(finder: finder, sources: plan.sources, deadline: deps.markedItemsDeadline)
        if result != .busy { loggedStuckLook = false }
        switch result {
        case .found(let found): verified = found
        case .busy:
            // An earlier look is still blocked in Spotlight past its deadline: no new query (review I2). Logged once
            // per episode, not at every backup; the next look that runs again ends the episode.
            if !loggedStuckLook {
                loggedStuckLook = true
                deps.agentInfo(
                    "Not looking for items apps mark as not for backup for plan \(id): still waiting for Spotlight to "
                        + "answer an earlier look, so backups include them until it does")
            }
            return (nil, nil)
        case .gaveUp:
            deps.agentInfo(
                "Gave up looking for items apps mark as not for backup for plan \(id) (too many, too slow, or Spotlight "
                    + "couldn’t answer), so this backup includes them")
            return (nil, nil)
        }
        let collapsed = MarkedNotForBackup.collapse(
            verified, sources: plan.sources, exclusions: plan.exclusions, backUpAnyway: plan.backUpAnyway)
        let file = MarkedNotForBackup.excludeFile(collapsed)
        let unlogged = file.unrepresentable.filter { loggedUnrepresentable.insert($0).inserted }
        if !unlogged.isEmpty {
            deps.agentInfo(
                "Backing up \(unlogged.count) item(s) apps mark as not for backup, because restic can't be given their "
                    + "names exactly (plan \(id)): " + unlogged.map(\.debugDescription).joined(separator: ", "))
        }
        guard !file.written.isEmpty else { return (nil, 0) }
        let url = deps.notForBackupDirectory.appendingPathComponent("\(id).txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: deps.notForBackupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try PrivateFile.write(Data(file.text.utf8), to: url, what: "the list of items marked not for backup")
        } catch {
            deps.agentLog("\(error), so this backup of plan \(id) includes the items apps mark as not for backup")
            return (nil, nil)
        }
        return (url, file.written.count)
    }

    private func removeNotForBackupList(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// `restic stats --mode raw-data`, recorded, and its total kept as the plan's repository size with the
    /// time it was measured (Ruling P2-9). Runs inside the caller's turn of the repository's queue. A failure
    /// fails nothing else and raises no alert (only backups and checks do): the size measured before stays,
    /// and the reason goes to `agent.log`. Returns the step's outcome, so an interrupted one stops what follows.
    func measureRepository(session: RunSession, trigger: RunTrigger, handle: RunHandle) async -> RunOutcome {
        let plan = session.plan
        let collector = LineCollector(matching: StatsSummary.isStats)
        let step = await runStep(.stats, trigger: trigger, session: session, handle: handle, collector: collector)
        await commit(step.record, plan: plan)
        let problem: String
        switch step.record.outcome {
        case .success:
            do {
                let stats = try StatsSummary.parse(collector.last ?? "")
                let size = RepositorySize(bytes: stats.totalSize, measuredAt: step.record.endedAt)
                await write(plan.id) { $0.repositorySize = size }
                return step.record.outcome
            } catch {
                problem = "restic’s stats reply couldn’t be read"
            }
        case let outcome:
            problem = Self.explain(outcome, stoppedReason: step.stoppedReason)
        }
        deps.agentLog(
            "Couldn't measure the repository size for plan \(plan.id.uuidString), so the last size measured is kept: \(problem)")
        return step.record.outcome
    }

    /// Where a link to the plan's local repository leads, for its exclusion. Following it reads the disk, which a volume
    /// that doesn't answer can hold up for good, so it goes through `deps.linkResolver` (final review round 2). Nil for
    /// a repository that isn't a local folder, or when the answer didn't come in time: the backup then excludes the
    /// path as given only.
    func repositoryLinkTarget(_ plan: Plan) async -> String? {
        guard let repositoryPath = plan.repository.localFolderPath else { return nil }
        guard let target = await deps.linkResolver.resolve([repositoryPath])?.first else {
            if !loggedStuckLinkCheck {
                loggedStuckLinkCheck = true
                deps.agentInfo("Couldn’t find out where the repository folder of plan \(plan.id.uuidString) leads: the file "
                    + "system didn’t answer, so only the folder as given is left out of this backup (not logged again "
                    + "until a check answers)")
            }
            return nil
        }
        loggedStuckLinkCheck = false
        return target
    }
}
