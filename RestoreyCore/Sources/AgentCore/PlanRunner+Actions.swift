import Foundation
import RestoreyCore

/// The app's one-off restic actions: creating a repository, probing an address, and listing a repository
/// for adoption. No preflight, no Full Disk Access probe, no pings and no maintenance. An action that would
/// start a restic step while the agent is winding down (it waited in the repository's queue while a drain
/// began) is refused as draining, with no record (Ruling R55).
extension PlanRunner {
    /// Runs `restic init`. Never called on its own: only this explicit action creates a repository.
    public func createRepository(planID: UUID) async throws -> AgentStatus {
        let handle = try await begin(planID)
        let result = await initialise(planID: planID, handle: handle)
        await end(planID, handle)
        try result.get()
        return await deps.state.status()
    }

    /// Lists the repository's snapshots for every host and replies with what it found. Never forgets or
    /// changes anything. The repository's size (`stats`, Ruling P2-9) is measured afterwards as its own job,
    /// next in the repository's queue (`measureAfterAdoption`): on a large remote repository with a cold
    /// cache it can take far longer than the listing, and the adopt mustn't wait for it or fail with it.
    public func adopt(planID: UUID) async throws -> AdoptReport {
        let handle = try await begin(planID)
        let result = await listForAdoption(planID: planID, handle: handle)
        await end(planID, handle)
        return try result.get()
    }

    /// What is at the plan's repository address (Ruling P2-2): `restic cat config`, then, if a repository
    /// is there, the same listing as `adopt`, in one turn of the repository's queue. Exit 10 is `.empty`; a
    /// password that doesn't open the repository (exit 12) is `.passwordRejected`; anything else gets the
    /// create probe's sentences (`probeFailureMessage`). Each step is recorded like adopt's, and none of
    /// them stops the plan: the user is still choosing what to back up to. Never creates or changes anything.
    public func probeRepository(planID: UUID) async throws -> RepositoryProbe {
        let handle = try await begin(planID)
        let result = await probe(planID: planID, handle: handle)
        await end(planID, handle)
        return try result.get()
    }

    /// Settings' check of typed credentials before it saves them (Ruling R2): what `probeRepository` would find with
    /// `candidates` in place of the keychain's. A check, not a run, and a short repository action like the size
    /// measurement after an adopt: it isn't a run of the plan, so the plan isn't shown backing up and Back Up Now
    /// isn't refused (the backup waits its turn in the repository's queue, behind the check). Like the measurement,
    /// it is registered with the state only once its turn comes, so a drain waits for it and deleting the plan
    /// stops it, while a check still waiting (behind another plan's backup, say) holds up neither; it then finds the
    /// plan gone and runs nothing. It records nothing: no history record, no in-progress marker, no run log. Its
    /// outcome goes back only as the reply.
    ///
    /// The candidates are set (`AgentState.candidates`) only inside the check's turn of the queue and cleared with
    /// `defer` however it ends; they are in the redactor too.
    public func checkCredentials(planID: UUID, candidates: [SecretKey: String]) async throws -> RepositoryProbe {
        let handle = RunHandle()
        measurementHandles[planID, default: []].append(handle)
        let result = await check(planID: planID, candidates: candidates, handle: handle)
        measurementEnded(planID: planID, handle: handle)
        return try result.get()
    }

    private typealias CheckSteps = (probe: StepResult, listing: Result<AdoptReport, AgentError>?)

    private func check(
        planID: UUID, candidates: [SecretKey: String], handle: RunHandle
    ) async -> Result<RepositoryProbe, AgentError> {
        let session: RunSession
        switch await actionSession(planID: planID, overrides: candidates) {
        case .failure(let error): return .failure(error)
        case .success(let ready): session = ready
        }
        let turn = await deps.queues.run(repository: session.key) {
            [self] () async -> Result<CheckSteps, AgentError>? in
            guard !(await isWindingDown()), handle.intent == nil else { return nil }
            do {
                try await deps.state.beginMeasurement(planID: planID)
            } catch {
                return .failure((error as? AgentError) ?? .unknownPlan)
            }
            let steps = await checkSteps(planID: planID, candidates: candidates, session: session, handle: handle)
            await deps.state.endMeasurement(planID: planID)
            return .success(steps)
        }
        guard let turn else { return .failure(handle.intent == nil ? .draining : .unknownPlan) }
        return turn.flatMap { probeResult(probe: $0.probe, listing: $0.listing, session: session) }
    }

    /// The check's restic steps, with the candidates set for the helper only while they run.
    private func checkSteps(
        planID: UUID, candidates: [SecretKey: String], session: RunSession, handle: RunHandle
    ) async -> CheckSteps {
        let store = deps.state.candidates
        store.set(candidates, for: planID)
        defer { store.set(nil, for: planID) }
        let probe = await runStep(.catConfig, trigger: .manual, session: session, handle: handle, recorded: false)
        guard case .success = probe.record.outcome, !(await isWindingDown()) else { return (probe, nil) }
        return (probe, await listSnapshots(session: session, handle: handle, recorded: false))
    }

    /// Runs the agent's Full Disk Access probe, records it and pushes the status even when nothing
    /// changed, so the setup step polling it sees every answer (Ruling P2-11).
    public func probeFullDiskAccess() async -> AgentStatus {
        await deps.state.noteFullDiskAccess(deps.fdaProbe(), pushingAlways: true)
    }

    /// Probes with `restic cat config` first, in the same turn of the queue as the `init`: exit 0 means a
    /// repository is there and nothing is changed; exit 10 means nothing is, so `init` runs; anything else
    /// is reported as it is.
    private func initialise(planID: UUID, handle: RunHandle) async -> Result<Void, AgentError> {
        let session: RunSession
        switch await actionSession(planID: planID) {
        case .failure(let error): return .failure(error)
        case .success(let ready): session = ready
        }
        let steps = await deps.queues.run(repository: session.key) { [self] () async -> (StepResult, StepResult?)? in
            guard !(await isWindingDown()) else { return nil }
            let probe = await runStep(.catConfig, trigger: .manual, session: session, handle: handle)
            await commit(probe.record, plan: session.plan)
            guard probe.record.outcome == .repositoryMissing, !(await isWindingDown()) else { return (probe, nil) }
            let created = await runStep(.initRepository, trigger: .manual, session: session, handle: handle)
            await commit(created.record, plan: session.plan)
            return (probe, created)
        }
        guard let steps else { return .failure(.draining) }
        let (probe, created) = steps
        switch probe.record.outcome {
        case .success: return .failure(.repositoryAlreadyExists)
        case .repositoryMissing: break
        case let outcome:
            return .failure(.operationFailed(Self.probeFailureMessage(
                repository: session.plan.repository, outcome: outcome, stoppedReason: probe.stoppedReason,
                stderr: probe.tail)))
        }
        // A missing repository and no init: the agent began winding down after the probe.
        guard let created else { return .failure(.draining) }
        if case .success = created.record.outcome { return .success(()) }
        return .failure(.operationFailed(
            "Restorey couldn't create the repository: \(Self.explain(created.record.outcome, stoppedReason: created.stoppedReason))"))
    }

    /// What the app shows when `cat config` failed with something other than "nothing there". Init never
    /// runs after such a failure, whatever the text says; the text only chooses the explanation. An S3
    /// bucket that is missing (or that the key can't see) gets its own sentence. Restorey makes no bucket
    /// call of its own (Ruling R38): only `restic init`, after a probe that found nothing (exit 10), may
    /// create a missing bucket, and only when the key is allowed to. A probe that failed some other way
    /// never reaches init, so the user is told to create the bucket in the provider's console.
    static func probeFailureMessage(
        repository: Repository, outcome: RunOutcome, stoppedReason: String?, stderr: [String]
    ) -> String {
        if case .s3(let location) = repository {
            let text = (stderr + [explain(outcome, stoppedReason: stoppedReason)]).joined(separator: "\n")
            if missingBucketMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                return "The bucket \(location.bucket) doesn't exist or this key can't see it. Create it in your provider's console first"
            }
        }
        return "Restorey couldn't check the repository address: \(explain(outcome, stoppedReason: stoppedReason))"
    }

    /// minio-go's text for S3's `NoSuchBucket` ("The specified bucket does not exist.") and the code itself.
    static let missingBucketMarkers = ["NoSuchBucket", "specified bucket does not exist"]

    private func listForAdoption(planID: UUID, handle: RunHandle) async -> Result<AdoptReport, AgentError> {
        let session: RunSession
        switch await actionSession(planID: planID) {
        case .failure(let error): return .failure(error)
        case .success(let ready): session = ready
        }
        let listed = await deps.queues.run(repository: session.key) { [self] () async -> Result<AdoptReport, AgentError>? in
            guard !(await isWindingDown()) else { return nil }
            let listing = await listSnapshots(session: session, handle: handle)
            // Queued from inside this turn, so it is next in line, ahead of the plan's first backup.
            if case .success = listing { await queueMeasurementAfterAdoption(planID: planID, key: session.key) }
            return listing
        }
        return listed ?? .failure(.draining)
    }

    private func probe(planID: UUID, handle: RunHandle) async -> Result<RepositoryProbe, AgentError> {
        let session: RunSession
        switch await actionSession(planID: planID) {
        case .failure(let error): return .failure(error)
        case .success(let ready): session = ready
        }
        let probed = await deps.queues.run(repository: session.key) {
            [self] () async -> (StepResult, Result<AdoptReport, AgentError>?)? in
            guard !(await isWindingDown()) else { return nil }
            let probe = await runStep(.catConfig, trigger: .manual, session: session, handle: handle)
            await commit(probe.record, plan: session.plan)
            guard case .success = probe.record.outcome, !(await isWindingDown()) else { return (probe, nil) }
            return (probe, await listSnapshots(session: session, handle: handle))
        }
        guard let (probe, listing) = probed else { return .failure(.draining) }
        return probeResult(probe: probe, listing: listing, session: session)
    }

    /// The probe's answer from its `cat config` and, when a repository is there, its listing.
    private func probeResult(
        probe: StepResult, listing: Result<AdoptReport, AgentError>?, session: RunSession
    ) -> Result<RepositoryProbe, AgentError> {
        switch probe.record.outcome {
        case .repositoryMissing: return .success(RepositoryProbe(state: .empty))
        case .wrongPassword: return .success(RepositoryProbe(state: .passwordRejected))
        case .success:
            // A repository is there, but the agent began winding down before the listing.
            guard let listing else { return .failure(.draining) }
            return listing.map { RepositoryProbe(state: .existing($0)) }
        case let outcome:
            return .failure(.operationFailed(Self.probeFailureMessage(
                repository: session.plan.repository, outcome: outcome, stoppedReason: probe.stoppedReason,
                stderr: probe.tail)))
        }
    }

    /// `restic snapshots` for every host, recorded, and read into what `adopt` reports. Runs inside the
    /// caller's turn of the repository's queue.
    /// `recorded` false: a credential check's listing, kept out of the history (`checkCredentials`).
    private func listSnapshots(
        session: RunSession, handle: RunHandle, recorded: Bool = true
    ) async -> Result<AdoptReport, AgentError> {
        let collector = LineCollector(matching: SnapshotListing.isListing)
        let step = await runStep(
            .snapshots(allHosts: true), trigger: .manual, session: session, handle: handle, collector: collector,
            recorded: recorded)
        if recorded { await commit(step.record, plan: session.plan) }
        guard case .success = step.record.outcome else {
            return .failure(.operationFailed(Self.explain(step.record.outcome, stoppedReason: step.stoppedReason)))
        }
        do {
            return .success(try SnapshotListing.report(from: collector.last ?? "[]", hostLabel: session.plan.hostLabel))
        } catch {
            return .failure(.operationFailed("Restorey couldn't read restic's list of snapshots"))
        }
    }

    // MARK: Measuring after an adopt

    /// Queues `measureAfterAdoption` behind everything already in the repository's queue and returns at once.
    private func queueMeasurementAfterAdoption(planID: UUID, key: String) async {
        let handle = RunHandle()
        measurementHandles[planID, default: []].append(handle)
        let job = await deps.queues.enqueue(repository: key) { [self] () async -> Void in
            await measureAfterAdoption(planID: planID, key: key, handle: handle)
        }
        measurements[planID] = Task {
            await job.value()
            measurementEnded(planID: planID, handle: handle)
        }
    }

    private func measurementEnded(planID: UUID, handle: RunHandle) {
        measurementHandles[planID]?.removeAll { $0 === handle }
        if measurementHandles[planID]?.isEmpty == true { measurementHandles[planID] = nil }
    }

    /// Waits for the latest measurement queued after an adopt of the plan. For tests.
    func waitForMeasurement(planID: UUID) async {
        await measurements[planID]?.value
    }

    /// Asks the plan's measurements after an adopt to stop: one running is cancelled, one still waiting
    /// never starts. `AgentState.deletePlan` is the way in.
    func stopMeasurement(planID: UUID) async {
        for handle in measurementHandles[planID] ?? [] {
            guard let process = handle.request(.cancel) else { continue }
            await process.interrupt(.cancel, killAfter: deps.interruptGracePeriod)
        }
    }

    /// The measurement after an adopt, in its own turn of the repository's queue. It isn't a run of the plan
    /// (the plan stays idle, and Back Up Now isn't refused), but it is registered with the state, so a drain
    /// waits for it. It doesn't start, and says why in `agent.log`, when the plan was paused, deleted or
    /// moved to another repository while it waited, or the agent is winding down.
    private func measureAfterAdoption(planID: UUID, key: String, handle: RunHandle) async {
        func skipped(_ reason: String) {
            deps.agentLog("Didn't measure the repository size after adopting it, for plan \(planID.uuidString): \(reason)")
        }
        guard handle.intent == nil else { return skipped("the plan was paused or deleted first") }
        guard !(await isWindingDown()) else { return skipped(AgentError.draining.message) }
        do {
            try await deps.state.beginMeasurement(planID: planID)
        } catch {
            return skipped((error as? AgentError)?.message ?? "\(error)")
        }
        if let until = try? await deps.state.runInputs(planID).history.pausedUntil, until > deps.now() {
            skipped("the plan is paused")
        } else {
            switch await actionSession(planID: planID) {
            case .failure(let error): skipped(error.message)
            case .success(let session) where session.key != key: skipped("its repository has changed")
            case .success(let session): _ = await measureRepository(session: session, trigger: .manual, handle: handle)
            }
        }
        await deps.state.endMeasurement(planID: planID)
    }

    /// `overrides`: typed credentials to use (and redact) in place of the keychain's (a credential check).
    private func actionSession(
        planID: UUID, overrides: [SecretKey: String] = [:]
    ) async -> Result<RunSession, AgentError> {
        guard let plan = try? await deps.state.runInputs(planID).plan else { return .failure(.unknownPlan) }
        let errors = plan.validationErrors()
        guard errors.isEmpty else { return .failure(.invalidPlan(errors)) }
        switch prepare(plan, overrides: overrides) {
        case .ready(let session): return .success(session)
        case .failed(_, let reason, _): return .failure(.operationFailed(reason))
        }
    }
}
