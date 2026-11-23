import Foundation
import RestoreyCore

/// The app's calls on plans: saving, deleting and confirming them, their history and recovery kit, the network
/// settings, and pausing, cancelling and resuming.
extension AgentState {
    // MARK: Plans

    /// Validates, writes the secrets, then the config. If a secret write or the config write fails,
    /// every submitted secret is put back as it was (new keys deleted) and the config is unchanged.
    ///
    /// `recoveryKitConfirmedAt` is agent-owned. A new plan starts unconfirmed. An existing plan keeps its
    /// confirmation only if the repository is the same and every submitted secret equals the keychain's
    /// current value; otherwise the recovery details the user saved no longer match, so it is cleared.
    /// `setupCompletedAt` and `offMacNoteDismissed` are agent-owned too: a new plan starts without them and
    /// an existing plan keeps the stored values, whatever the request says (Ruling P2-3). Only
    /// `confirmRecoveryKit` and `dismissOffMacNote` set them. So is `credentialsVersion`: 0 for a new plan, and one
    /// more whenever the save changes the repository or a secret that opens it (the change that clears the
    /// confirmation), which is what makes a kit shown before the change refuse to confirm (Task 9). An existing plan
    /// keeps its stored `exclusionDefaultsRevision` (`addNewDefaultExclusions` moves it on); a new plan keeps the
    /// request's, the revision of the defaults the app made its list from.
    ///
    /// The same change also clears a stop (`stoppedReason`, e.g. after a wrong password) and refreshes the
    /// plan's alerts: the user has changed what restic opens the repository with, so the next run tries it
    /// (Ruling R34). An unchanged resave keeps the stop.
    ///
    /// A changed check-in URL, or none (`hasCheckInURL` false), clears `checkInRejected` (Ruling R48): that
    /// verdict was about the old URL, and with no URL it could never clear.
    ///
    /// `hasCheckInURL: false` deletes any stored check-in URL (and a check-in URL sent with it is refused).
    /// Clients must carry `hasCheckInURL` over from the stored plan like any other field, since they can't
    /// read the URL back: sending `false` for a plan that has one removes its dead-man's switch.
    public func savePlan(_ request: SavePlanRequest) async throws -> AgentStatus {
        try requireMutable()
        let errors = request.plan.validationErrors()
        guard errors.isEmpty else { throw AgentError.invalidPlan(errors) }
        guard request.secrets.allSatisfy({ $0.key.planID == request.plan.id }) else {
            throw AgentError.foreignSecret
        }
        let checkInKey = SecretKey.checkInURL(request.plan.id)
        if !request.plan.hasCheckInURL, request.secrets.contains(where: { $0.key == checkInKey }) {
            throw AgentError.invalidRequest("a check-in URL was sent for a plan saved without one")
        }
        return try await serialisedWrite {
            // Validation compares paths only (it runs on every status); here, where the user acts, a source that
            // reaches the repository through a link is refused too. Inside the serialised section, so saves still
            // complete in the order they arrived (final review round 2).
            try await refuseSourcesReachingTheRepositoryThroughLinks(request.plan)
            // A plan saved without a check-in URL loses any stored one, so it is never pinged.
            let planSecrets = try PlanSecrets(
                store: secrets, entries: request.secrets,
                deletions: request.plan.hasCheckInURL ? [] : [checkInKey])
            var plan = request.plan
            plan.normaliseFileTypeExclusions()
            var updated = config
            var credentialsChanged = false
            let checkInChanged = !plan.hasCheckInURL || planSecrets.changesValue(of: .checkInURL(plan.id))
            if let index = updated.plans.firstIndex(where: { $0.id == plan.id }) {
                let stored = updated.plans[index]
                // The recovery kit holds the address, the password, the backend keys and the host label its
                // restore commands pass as `--host`: a change to any of them needs a new kit before backups carry
                // on. The check-in URL isn't needed to restore (product spec §7), so changing it from the Alerts
                // tab doesn't pause backups.
                // Only a new address or secret can cure a stop (a wrong password, a missing repository); a new
                // label can't, so it doesn't clear one.
                credentialsChanged = stored.repository != plan.repository
                    || planSecrets.changesAnyValue(excluding: [checkInKey])
                let kitStillHolds = !credentialsChanged && stored.hostLabel == plan.hostLabel
                plan.recoveryKitConfirmedAt = kitStillHolds ? stored.recoveryKitConfirmedAt : nil
                plan.setupCompletedAt = stored.setupCompletedAt
                plan.offMacNoteDismissed = stored.offMacNoteDismissed
                plan.credentialsVersion = stored.credentialsVersion + (credentialsChanged ? 1 : 0)
                // The agent's (`addNewDefaultExclusions`): an editor opened before a default was added mustn't lower it,
                // or a default the person then removed would be added again.
                plan.exclusionDefaultsRevision = stored.exclusionDefaultsRevision
                updated.plans[index] = plan
            } else {
                plan.recoveryKitConfirmedAt = nil
                plan.setupCompletedAt = nil
                plan.offMacNoteDismissed = false
                plan.credentialsVersion = 0
                updated.plans.append(plan)
            }

            try planSecrets.write()
            do {
                try await saveConfig(updated)
            } catch {
                let message = (error as? AgentError)?.message ?? "\(error)"
                throw AgentError.storage(message + PlanSecrets.describe(planSecrets.restore()))
            }
            let clearStop = credentialsChanged && runState.plans[plan.id]?.stoppedReason != nil
            let clearCheckIn = checkInChanged && runState.plans[plan.id]?.activeAlerts[.checkInRejected] != nil
            if checkInChanged { checkInRejectedStatus[plan.id] = nil }
            if clearStop || clearCheckIn {
                var state = runState
                if clearStop {
                    state.plans[plan.id]?.stoppedReason = nil
                    PlanRunner.refreshAlerts(&state.plans[plan.id, default: PlanRunHistory()], plan: plan, now: now())
                }
                if clearCheckIn { state.plans[plan.id]?.activeAlerts[.checkInRejected] = nil }
                do {
                    try await saveState(state)
                } catch {
                    let detail = (error as? AgentError)?.message ?? "\(error)"
                    let what = clearStop ? "its stop" : "its check-in alert"
                    throw AgentError.storage("\(plan.name) was saved, but Restorey couldn’t clear \(what): \(detail)")
                }
            }
            return pushStatus()
        }
    }

    /// Removes the plan from the config, then its secrets, credentials file, history and run logs. The
    /// repository is never touched. A running plan cannot be deleted, and from the moment this is called
    /// no run can begin on the plan.
    public func deletePlan(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        let plan = try requirePlan(id)
        guard !deleting.contains(id) else { throw AgentError.planDeleting(name: plan.name) }
        guard running[id] == nil else { throw AgentError.planRunning(name: plan.name) }
        // Without a runner the agent is still in start-up recovery (`main.swift` attaches it afterwards), and a
        // registration then is recovery's unlock, which nothing can stop yet: refused at once, as Back Up Now is,
        // rather than waiting for restic.
        if measuring[id] != nil, runner == nil { throw AgentError.runnerUnavailable }
        // Marked before the first await, so beginRun can't slip in while this waits on the stores.
        deleting.insert(id)
        defer { deleting.remove(id) }
        // A measurement after an adopt is stopped rather than refusing the delete (setup's Cancel deletes the
        // plan it just adopted). restic has `interruptGracePeriod` to stop; its record is written before the
        // plan goes. One still waiting in the queue finds the plan gone and doesn't start.
        if measuring[id] != nil {
            await runner?.stopMeasurement(planID: id)
            while measuring[id] != nil { await withCheckedContinuation { measuringWaiters.append($0) } }
        }

        return try await serialisedWrite {
            var updated = config
            updated.plans.removeAll { $0.id == id }
            try await saveConfig(updated)

            // The plan is gone from the config, so finish every clean-up step before reporting a failure.
            var failures: [String] = []
            do { try secrets.deleteAll(planID: id) } catch { failures.append("its Keychain items (\(error))") }
            do {
                try CredentialsFile.remove(planID: id, directory: credentialsDirectory)
            } catch {
                failures.append("its credentials file (\(error))")
            }
            if runState.plans[id] != nil {
                var state = runState
                state.plans[id] = nil
                do { try await saveState(state) } catch { failures.append("its history (\(error))") }
            }
            // Gone now rather than at the 400-day prune: they would only be found by browsing the folder.
            if let runLogs {
                do { try await runLogs.removePlan(id) } catch { failures.append("its run logs (\(error.localizedDescription))") }
            }
            let status = pushStatus()
            if !failures.isEmpty {
                throw AgentError.storage(
                    "\(plan.name) was deleted, but Restorey couldn’t remove \(failures.joined(separator: " or "))")
            }
            return status
        }
    }

    /// Records that the user has saved the plan's recovery details, with nothing checked and nothing started: an app
    /// from before Task 9, and the developer window.
    public func confirmRecoveryKit(_ id: UUID) async throws -> AgentStatus {
        try await confirmRecoveryKit(planID: id, kitDigest: nil, startFirstBackup: false)
    }

    /// Records that the user has saved the plan's recovery details. Until then the plan never runs
    /// on its own. The first confirmation also finishes setup (`setupCompletedAt`, Ruling P2-3).
    ///
    /// `kitDigest` is `RecoveryKitDocument.digest` of the kit the person saved. When it no longer matches the plan as
    /// stored (its repository, a key or the host label changed since the kit was shown, Task 9) the confirmation is
    /// refused with `recoveryKitChanged` and nothing is confirmed. Nil checks nothing.
    ///
    /// `startFirstBackup` is setup's Start: the runner registers a manual backup's handle, then the confirmation is
    /// saved and the run registered with no suspension point between them (`confirmKit`), so no status and no read
    /// by the scheduler (`scheduleInputs`) ever has the plan confirmed but not running, and the backup that runs is
    /// this one. Refused, with nothing confirmed, when the runner isn't attached yet, the plan is invalid or it is
    /// already running.
    public func confirmRecoveryKit(planID id: UUID, kitDigest: String?, startFirstBackup: Bool) async throws -> AgentStatus {
        try requireMutable()
        let plan = try requirePlan(id)
        guard startFirstBackup else { return try await confirmKit(id, kitDigest: kitDigest, beginningRun: false).status }
        let errors = plan.validationErrors()
        guard errors.isEmpty else { throw AgentError.invalidPlan(errors) }
        return try await requireRunner().startFirstBackup(planID: id, kitDigest: kitDigest)
    }

    /// The confirmation itself, through the write gate; with `beginningRun` (the runner holds the run's handle) it
    /// also registers the run, as `beginRun` does, in the same synchronous step that makes the confirmation visible:
    /// `config` and `running` change together after the save, so nothing on this actor can see one without the other.
    /// No run is registered when a drain or a delete began while the config was being saved; the plan is then
    /// confirmed and the next agent's scheduler finds it due (`began` false).
    func confirmKit(_ id: UUID, kitDigest: String?, beginningRun: Bool) async throws -> (status: AgentStatus, began: Bool) {
        try await serialisedWrite {
            var updated = config
            guard let index = updated.plans.firstIndex(where: { $0.id == id }) else { throw AgentError.unknownPlan }
            let plan = updated.plans[index]
            if let kitDigest, kitDigest != RecoveryKitDocument.digest(for: plan) { throw AgentError.recoveryKitChanged }
            if beginningRun {
                try requireMutable()
                guard !deleting.contains(id) else { throw AgentError.planDeleting(name: plan.name) }
                guard running[id] == nil else { throw AgentError.alreadyRunning(name: plan.name) }
            }
            let now = now()
            updated.plans[index].recoveryKitConfirmedAt = now
            if updated.plans[index].setupCompletedAt == nil { updated.plans[index].setupCompletedAt = now }
            try await writeConfig(updated)
            // No suspension point from here to the return.
            config = updated
            let began = beginningRun && !isDraining && !deleting.contains(id) && running[id] == nil
            if began { running[id] = RunProgress() }
            return (pushStatus(), began)
        }
    }

    /// Records that the user dismissed the plan's "No off-Mac monitoring" note. It stays dismissed: no saved
    /// plan can bring it back.
    public func dismissOffMacNote(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        _ = try requirePlan(id)
        return try await serialisedWrite {
            var updated = config
            guard let index = updated.plans.firstIndex(where: { $0.id == id }) else { throw AgentError.unknownPlan }
            updated.plans[index].offMacNoteDismissed = true
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// The run records of one plan, or of every plan when `id` is nil, newest (by end) first (Ruling P2-4):
    /// each plan's `recent`, and its `lastBackupRecord` when that has fallen out of `recent`. Answered while
    /// draining; refused in the config-error state.
    public func history(_ id: UUID?) throws -> [RunRecord] {
        try requireLoaded()
        let plans = try id.map { [try requirePlan($0)] } ?? config.plans
        let records = plans.flatMap { plan -> [RunRecord] in
            let history = runState.plans[plan.id] ?? PlanRunHistory()
            guard let last = history.lastBackupRecord, !history.recent.contains(where: { $0.id == last.id }) else {
                return history.recent
            }
            return history.recent + [last]
        }
        // Stable: records that ended together keep their plan's order.
        return records.enumerated()
            .sorted { a, b in
                a.element.endedAt != b.element.endedAt ? a.element.endedAt > b.element.endedAt : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The plan and every secret the agent holds for it, for the recovery kit (Ruling P2-5): the repository
    /// password; an S3 plan's two keys or a raw plan's environment values, in the plan's order; and the
    /// check-in URL when the plan has one. The XPC listener serves only the signed app, which holds the
    /// reply only while the kit is open. A secret that can't be read, or is missing, refuses the kit (a kit
    /// without it would fail the user in a disaster); the error names the Keychain account, never a value.
    /// Read inside the write gate, so a save in progress can't pair one plan's secrets with another version.
    public func recoveryKit(_ id: UUID) async throws -> RecoveryKitSecrets {
        try requireLoaded()
        _ = try requirePlan(id)
        return try await serialisedWrite {
            let plan = try requirePlan(id)
            var keys = plan.credentialKeys
            if plan.hasCheckInURL { keys.append(.checkInURL(id)) }
            let entries = try keys.map { key in
                let value: String?
                do {
                    value = try secrets.read(key)
                } catch {
                    throw AgentError.storage("Restorey couldn’t read \(key.account) from the Keychain: \(error)")
                }
                guard let value else {
                    throw AgentError.storage("\(key.account) isn’t in the Keychain, so the recovery kit would be incomplete")
                }
                return SecretEntry(key: key, value: value)
            }
            return RecoveryKitSecrets(plan: plan, secrets: entries)
        }
    }

    /// Saves the Mac-wide network rules (Ruling P2-6) beside the plans in `config.json`, Wi-Fi names
    /// trimmed, and pushes the status. Settings with any problem are refused with every reason and nothing
    /// is saved (Review Focus 5). They apply from the next restic step: a backup already uploading keeps
    /// the limit it started with, since restic can't change it mid-run (Ruling P2-7).
    public func saveNetworkSettings(_ settings: NetworkSettings) async throws -> AgentStatus {
        try requireMutable()
        let errors = settings.validationErrors()
        guard errors.isEmpty else { throw AgentError.invalidNetworkSettings(errors) }
        return try await serialisedWrite {
            var updated = config
            updated.network = settings.normalised()
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Saves which notifications are posted, beside the plans in `config.json`, and pushes the status. Three
    /// booleans have no invalid value, so there is nothing to refuse beyond the usual `requireMutable()`.
    public func saveNotificationSettings(_ settings: NotificationSettings) async throws -> AgentStatus {
        try requireMutable()
        return try await serialisedWrite {
            var updated = config
            updated.notifications = settings
            try await saveConfig(updated)
            return pushStatus()
        }
    }

    /// Pauses for `length`, after which the plan is due at once, and asks the runner to stop a
    /// run in progress (SIGINT, then SIGKILL; the run ends `.paused`). Allowed while draining.
    public func pause(_ id: UUID, for length: PauseLength) async throws -> AgentStatus {
        try requireLoaded()
        let until = now().addingTimeInterval(length.seconds)
        let status = try await updateHistory(id) { $0.pausedUntil = until }
        await runner?.interrupt(planID: id, intent: .pause)
        return status
    }

    /// Stops the plan's run in progress, this run only: the schedule carries on, so nothing is saved and
    /// `pausedUntil` is left alone. The run ends `.cancelled`: no ping, no failure alert, no maintenance
    /// after it, and the next backup falls at its normal time (not the short retry). With no run in progress
    /// the status comes back unchanged. A run a pause is already stopping keeps the pause (`handle.request`
    /// returns nil once an intent is set). Allowed while draining, like `pause`, since it only stops work.
    /// The reply says what the Cancel did (`CancelOutcome`): the agent's log has a line only when it stopped something,
    /// and the Cancel Backup shortcut says when a pause had already won.
    public func cancel(_ id: UUID) async throws -> CancelReply {
        try requireLoaded()
        _ = try requirePlan(id)
        let outcome = await runner?.cancel(planID: id) ?? .nothingToCancel
        return CancelReply(status: status(), outcome: outcome)
    }

    /// Clears the plan's pause. When it was paused (`pausedUntil` still in the future), Resume also starts
    /// a fresh backup at once (spec §3, Ruling R59), through Back Up Now, so the pre-run conditions and
    /// the recovery-kit refusal are exactly Back Up Now's: a skip for battery or network is a fine
    /// outcome, and a refusal is thrown after the pause has been cleared. A run still stopping for the
    /// pause isn't "already backing up": the fresh backup starts as soon as it has ended (Ruling R62). A stopped plan
    /// (`stoppedReason`) has its pause cleared and starts nothing: it waits for its repository or secrets
    /// to be fixed, as the scheduler does. A plan that wasn't paused only returns the status. The pause
    /// running out on its own is the scheduler's catch-up run, not this.
    public func resume(_ id: UUID) async throws -> AgentStatus {
        try requireMutable()
        let start = try await serialisedWrite {
            _ = try requirePlan(id)
            var state = runState
            let history = state.plans[id] ?? PlanRunHistory()
            let wasPaused = history.pausedUntil.map { $0 > now() } ?? false
            state.plans[id, default: PlanRunHistory()].pausedUntil = nil
            try await saveState(state)
            pushStatus()
            return wasPaused && history.stoppedReason == nil
        }
        guard start else { return status() }
        try requireRunnable(id)
        return try await requireRunner().backUpNow(id, afterPausedRun: true).status
    }

    /// Changes one plan's history and saves `state.json`, through the write gate. The runner records
    /// every run through this.
    @discardableResult
    func updateHistory(
        _ id: UUID, _ change: @Sendable (inout PlanRunHistory) -> Void
    ) async throws -> AgentStatus {
        _ = try requirePlan(id)
        return try await serialisedWrite {
            _ = try requirePlan(id)
            var state = runState
            change(&state.plans[id, default: PlanRunHistory()])
            try await saveState(state)
            return pushStatus()
        }
    }
}
