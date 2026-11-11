import Foundation
import RestoreyCore

/// The app's one-off restic actions: creating a repository and listing one for adoption. No preflight,
/// no probe, no pings and no maintenance. An action that would start a restic step while the agent is
/// winding down (it waited in the repository's queue while a drain began) is refused as draining,
/// with no record (Ruling R55).
extension PlanRunner {
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
        let collector = LineCollector(matching: SnapshotListing.isListing)
        let session: RunSession
        switch await actionSession(planID: planID) {
        case .failure(let error): return .failure(error)
        case .success(let ready): session = ready
        }
        let listed = await deps.queues.run(repository: session.key) { [self] () async -> StepResult? in
            guard !(await isWindingDown()) else { return nil }
            return await runStep(
                .snapshots(allHosts: true), trigger: .manual, session: session, handle: handle, collector: collector)
        }
        guard let step = listed else { return .failure(.draining) }
        await commit(step.record, plan: session.plan)
        guard case .success = step.record.outcome else {
            return .failure(.operationFailed(Self.explain(step.record.outcome, stoppedReason: step.stoppedReason)))
        }
        do {
            return .success(try SnapshotListing.report(from: collector.last ?? "[]", hostLabel: session.plan.hostLabel))
        } catch {
            return .failure(.operationFailed("Restorey couldn't read restic's list of snapshots"))
        }
    }

    private func actionSession(planID: UUID) async -> Result<RunSession, AgentError> {
        guard let plan = try? await deps.state.runInputs(planID).plan else { return .failure(.unknownPlan) }
        let errors = plan.validationErrors()
        guard errors.isEmpty else { return .failure(.invalidPlan(errors)) }
        switch prepare(plan) {
        case .ready(let session): return .success(session)
        case .failed(_, let reason, _): return .failure(.operationFailed(reason))
        }
    }
}
