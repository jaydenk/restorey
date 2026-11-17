import Foundation
import RestoreyCore

/// Retention for a plan's earlier snapshots, the two opt-in actions of product spec §5.6 (Task 14b): the snapshots this
/// Mac made before Restorey adopted the repository, and those the plan made of a previous folder list. Nothing older
/// is ever thinned unless the user confirmed that specific action.
///
/// - The preview is `forget --dry-run --no-lock` with the plan's retention over a timeline holding the earlier snapshots
///   and the plan's current ones (`ResticOperation.forgetPreview`; one for the snapshots from before adoption, for an
///   adopted plan only, and one for previous folder lists), read by `EarlierSnapshots`, which keeps, snapshot by
///   snapshot, only those the actions are about. A dry run: it is never recorded (no history record, no in-progress
///   marker, no run log), like a credential check.
/// - A removal runs a fresh preview in the same turn of the repository's queue, then `forget <ids>` with exactly the
///   confirmed IDs that preview still puts in the action (`EarlierSnapshots.removable`): a snapshot added after the
///   confirmation can't be taken along, and one that has gone since is simply left out. restic takes its exclusive
///   lock and waits for another client's with `--retry-lock`, like the other maintenance; a lock still held then ends
///   the removal with nothing removed, and Restorey never breaks it. It is recorded, with its log. No prune: the
///   plan's own prune schedule frees the space.
///
/// Both are short repository actions like the size measurement after an adopt (`checkCredentials` has the details):
/// not runs of the plan, so the plan isn't shown backing up and Back Up Now isn't refused; they wait their turn behind
/// a backup. A pause, a delete and a system stop reach them as they reach runs.
extension PlanRunner {
    /// What the plan's retention would remove from its earlier groups now. Removes nothing and records nothing.
    public func previewEarlierSnapshots(planID: UUID) async throws -> EarlierSnapshotsPreview {
        try await inRepositoryTurn(planID: planID) { [self] session, handle in
            let kinds: [EarlierSnapshotKind] =
                session.plan.origin == .adopted ? [.beforeAdoption, .previousFolderLists] : [.previousFolderLists]
            return await earlierGroups(kinds, session: session, handle: handle).map(EarlierSnapshotsPreview.init(groups:))
        }.get()
    }

    /// Removes the confirmed snapshots that a fresh preview still puts in the confirmation's action, and replies with
    /// how many went. A lock held elsewhere, an interruption or a failure is the error's sentence.
    public func removeEarlierSnapshots(
        planID: UUID, confirmation: EarlierSnapshotsConfirmation
    ) async throws -> EarlierSnapshotsRemoval {
        let result = try await inRepositoryTurn(planID: planID) { [self] session, handle in
            .success(await removeEarlier(confirmation, session: session, handle: handle, trigger: .manual))
        }.get()
        switch result {
        case .removed(let removal): return removal
        case .notFinished(_, let sentence), .failed(let sentence): throw AgentError.operationFailed(sentence)
        }
    }

    // MARK: Steps

    enum EarlierRemoval: Sendable, Equatable {
        case removed(EarlierSnapshotsRemoval)
        /// No verdict: another client's lock, a pause, a delete, a system stop or an update. Worth trying again.
        case notFinished(RunOutcome, String)
        case failed(String)
    }

    /// The previews' restic steps (one per kind) and their reading. Inside the caller's turn of the repository's queue.
    private func earlierGroups(
        _ kinds: [EarlierSnapshotKind], session: RunSession, handle: RunHandle
    ) async -> Result<[EarlierSnapshotGroup], AgentError> {
        var groups: [EarlierSnapshotGroup] = []
        for kind in kinds {
            let collector = LineCollector(matching: ForgetReport.isReport)
            let step = await runStep(
                .forgetPreview(kind), trigger: .manual, session: session, handle: handle, collector: collector,
                recorded: false)
            guard case .success = step.record.outcome else {
                return .failure(.operationFailed(
                    "Restorey couldn’t count the earlier snapshots: \(Self.explain(step.record.outcome, stoppedReason: step.stoppedReason))"))
            }
            do {
                // restic prints no reply at all when no snapshot matches.
                groups += try EarlierSnapshots.groups(fromForgetReply: collector.last ?? "[]", kind: kind, plan: session.plan)
            } catch {
                return .failure(.operationFailed("Restorey couldn’t read restic’s list of snapshots to remove"))
            }
        }
        return .success(EarlierSnapshots.sorted(groups))
    }

    /// A fresh preview, then `forget` of the confirmed IDs still in scope, recorded. Inside the caller's turn of the
    /// repository's queue. With none left in scope restic isn't run, and the record says nothing needed removing.
    /// Every verdict is a History row, a refused confirmation and a failed preview included. `pending` (setup's choice,
    /// run after a backup): a failed preview isn't a verdict, since nothing was tried; the choice waits for the next
    /// backup, with no row (so a backend down for a day doesn't leave a row an hour).
    func removeEarlier(
        _ confirmation: EarlierSnapshotsConfirmation, session: RunSession, handle: RunHandle, trigger: RunTrigger,
        pending: Bool = false
    ) async -> EarlierRemoval {
        let plan = session.plan
        func failedRow(_ sentence: String) async -> EarlierRemoval {
            let now = deps.now()
            await commit(RunRecord(
                id: UUID(), planID: plan.id, operation: .forgetSnapshots(ids: confirmation.snapshotIDs), trigger: trigger,
                startedAt: now, endedAt: now, outcome: .failed(exitCode: Self.startFailureExitCode, reason: sentence),
                summary: nil, logFile: ""), plan: plan)
            return .failed(sentence)
        }
        if let problem = confirmation.problem(for: plan) {
            return await failedRow("Restorey can’t remove those snapshots: \(problem)")
        }
        let groups: [EarlierSnapshotGroup]
        switch await earlierGroups([confirmation.scope.kind], session: session, handle: handle) {
        case .success(let found): groups = found
        case .failure(let error):
            if let intent = handle.intent { return .notFinished(intent.outcome, Self.stoppedSentence) }
            if pending { return .notFinished(.failed(exitCode: Self.startFailureExitCode, reason: error.message), error.message) }
            return await failedRow(error.message)
        }
        let ids = EarlierSnapshots.removable(confirmation, now: groups)
        let confirmed = Set(confirmation.snapshotIDs).count
        if ids.isEmpty {
            let now = deps.now()
            await commit(RunRecord(
                id: UUID(), planID: plan.id, operation: .forgetSnapshots(ids: []), trigger: trigger, startedAt: now,
                endedAt: now, outcome: .success(snapshotID: nil), summary: nil, logFile: ""), plan: plan)
            return .removed(EarlierSnapshotsRemoval(removed: 0, leftAlone: confirmed))
        }
        if let intent = handle.intent { return .notFinished(intent.outcome, Self.stoppedSentence) }
        if await isWindingDown() { return .notFinished(.skipped(.agentUpdating), AgentError.draining.message) }

        // restic skips an ID it can't find with `Ignoring "<id>": …` on stderr and still exits 0 (0.19.1, verified):
        // one another client removed between the preview and now.
        let ignored = LineCollector(matching: { $0.hasPrefix("Ignoring \"") })
        var step = await runStep(.forgetSnapshots(ids: ids), trigger: trigger, session: session, handle: handle, collector: ignored)
        let gone = Set(ignored.all.compactMap(Self.ignoredID))
        if case .success = step.record.outcome {
            // The record names what restic removed, so History counts exactly what went.
            let removed = ids.filter { !gone.contains($0) }
            step.record.operation = .forgetSnapshots(ids: removed)
            await commit(step.record, plan: plan)
            return .removed(EarlierSnapshotsRemoval(removed: removed.count, leftAlone: confirmed - removed.count))
        }
        await commit(step.record, plan: plan)
        switch step.record.outcome {
        case .locked:
            return .notFinished(.locked, "Another program is using the repository and holds its lock, so no snapshots were removed. Restorey never breaks another program’s lock: try again once it has finished")
        case .paused, .cancelled, .stoppedBySystem:
            return .notFinished(step.record.outcome, Self.stoppedSentence)
        case let outcome:
            return .failed("Restorey couldn’t remove the earlier snapshots: \(Self.explain(outcome, stoppedReason: step.stoppedReason))")
        }
    }

    /// A backup that succeeded with every file: what setup's pending removal waits for.
    static func succeededFully(_ outcome: RunOutcome) -> Bool {
        switch outcome {
        case .success, .unchanged: true
        default: false
        }
    }

    static let stoppedSentence =
        "The removal was stopped before it finished. Snapshots already removed are gone; the rest are still there"

    /// The ID in restic's `Ignoring "<id>": <reason>`.
    static func ignoredID(_ line: String) -> String? {
        let parts = line.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return String(parts[1])
    }

    /// Setup's pending removal (`PlanRunHistory.pendingEarlierRemoval`), after a backup that saved the data, in the same
    /// turn of the queue. Returns whether the backup's maintenance (forget, prune, check) goes on after it. It doesn't
    /// when the removal was stopped (a lock held elsewhere, an interruption, an update): the confirmation then stays for the
    /// next backup and so does the maintenance. A preview that failed for any other reason (restic broke, or its reply
    /// couldn't be read) also leaves the confirmation for the next backup, but the maintenance goes on: the plan's own
    /// `forget` is scoped to its tag and can't touch the earlier snapshots, and `check` is independent, so holding them
    /// back would stop retention and integrity checking for as long as the failure lasted (final review I2). The failure
    /// is counted (`PendingRemovalFailures`) and the Overview says so from the third backup in a row. Any verdict clears the
    /// confirmation; a failure is in History and `agent.log`, and the user can apply retention from Settings → Keep.
    func runPendingEarlierRemoval(
        _ pending: EarlierSnapshotsConfirmation, session: RunSession, handle: RunHandle, trigger: RunTrigger
    ) async -> Bool {
        let planID = session.plan.id
        let result = await removeEarlier(pending, session: session, handle: handle, trigger: trigger, pending: true)
        switch result {
        case .notFinished(let outcome, let sentence):
            deps.agentLog("Left the confirmed removal of earlier snapshots for plan \(planID.uuidString) for its next backup: \(sentence)")
            // The preview failing is the only `.failed` here: a stop is its own outcome.
            guard case .failed = outcome else { return false }
            await countPendingRemovalFailure(planID: planID, ifStill: pending, reason: sentence)
            return true
        case .failed(let sentence):
            deps.agentLog("The confirmed removal of earlier snapshots for plan \(planID.uuidString) failed: \(sentence)")
        case .removed(let removal):
            deps.agentInfo(
                "Removed \(removal.removed) earlier snapshots for plan \(planID.uuidString) after its backup (\(removal.leftAlone) confirmed ones left)")
        }
        await clearPendingEarlierRemoval(planID: planID, ifStill: pending)
        return true
    }

    private func clearPendingEarlierRemoval(planID: UUID, ifStill pending: EarlierSnapshotsConfirmation) async {
        do {
            try await deps.state.updateHistory(planID) { history in
                // A newer confirmation that arrived meanwhile is kept for the next backup.
                if history.pendingEarlierRemoval == pending {
                    history.pendingEarlierRemoval = nil
                    history.pendingEarlierRemovalFailures = nil
                }
            }
        } catch {
            deps.agentLog("Couldn't clear the confirmed removal of earlier snapshots for plan \(planID.uuidString): \(error)")
        }
    }

    private func countPendingRemovalFailure(planID: UUID, ifStill pending: EarlierSnapshotsConfirmation, reason: String) async {
        do {
            try await deps.state.updateHistory(planID) { history in
                guard history.pendingEarlierRemoval == pending else { return }
                history.pendingEarlierRemovalFailures = PendingRemovalFailures(
                    count: (history.pendingEarlierRemovalFailures?.count ?? 0) + 1, reason: reason)
            }
        } catch {
            deps.agentLog("Couldn't count the failed removal of earlier snapshots for plan \(planID.uuidString): \(error)")
        }
    }

    // MARK: The repository's turn

    /// `body` in its own turn of the plan's repository queue, registered with the state only once the turn comes (so a
    /// drain waits for it and a delete stops it), as `checkCredentials` is. Refused as draining when the agent began
    /// winding down while it waited, and as an unknown plan when the plan was deleted.
    private func inRepositoryTurn<T: Sendable>(
        planID: UUID, _ body: @escaping @Sendable (RunSession, RunHandle) async -> Result<T, AgentError>
    ) async -> Result<T, AgentError> {
        let handle = RunHandle()
        measurementHandles[planID, default: []].append(handle)
        defer { measurementEnded(planID: planID, handle: handle) }
        let session: RunSession
        switch await actionSession(planID: planID) {
        case .failure(let error): return .failure(error)
        case .success(let ready): session = ready
        }
        let turn = await deps.queues.run(repository: session.key) { [self] () async -> Result<T, AgentError>? in
            guard !(await isWindingDown()), handle.intent == nil else { return nil }
            do {
                try await deps.state.beginMeasurement(planID: planID)
            } catch {
                return .failure((error as? AgentError) ?? .unknownPlan)
            }
            let result = await body(session, handle)
            await deps.state.endMeasurement(planID: planID)
            return result
        }
        guard let turn else { return .failure(handle.intent == nil ? .draining : .operationFailed(Self.stoppedSentence)) }
        return turn
    }
}
