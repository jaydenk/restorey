import Foundation
import RestoreyCore

/// The app's run actions and the runner's view of the plans. Every action is refused while draining or
/// in the config-error state (Ruling R27), then handed to the attached `PlanRunner`.
extension AgentState {
    /// Called once at startup, after the runner is built with this state.
    public func attach(runner: PlanRunner) {
        self.runner = runner
    }

    /// Backs up one plan, or every plan that may run when `id` is nil, in the background. Ignores the
    /// schedule but not the pre-run conditions. The reply shows the plan running.
    public func backUpNow(_ id: UUID?) async throws -> AgentStatus {
        try requireRunnable(id)
        return try await requireRunner().backUpNow(id)
    }

    /// Runs `restic init` for the plan: the only call that ever does. Refused when a repository exists.
    public func createRepository(_ id: UUID) async throws -> AgentStatus {
        try requireRunnable(id)
        return try await requireRunner().createRepository(planID: id)
    }

    /// Reads an existing repository's snapshots for every host. Never forgets anything.
    public func adopt(_ id: UUID) async throws -> AdoptReport {
        try requireRunnable(id)
        return try await requireRunner().adopt(planID: id)
    }

    func requireRunner() throws -> PlanRunner {
        guard let runner else { throw AgentError.runnerUnavailable }
        return runner
    }

    // MARK: For the runner

    /// The plan as configured and its history.
    func runInputs(_ id: UUID) throws -> (plan: Plan, history: PlanRunHistory) {
        (try requirePlan(id), runState.plans[id] ?? PlanRunHistory())
    }

    /// Every configured plan with its history; empty in the config-error state, where nothing may run.
    func allRunInputs() -> [(plan: Plan, history: PlanRunHistory)] {
        guard loadError == nil else { return [] }
        return config.plans.map { ($0, runState.plans[$0.id] ?? PlanRunHistory()) }
    }

    /// Records the latest Full Disk Access probe for `AgentStatus.fdaMissing`.
    func noteFullDiskAccess(_ result: FDAProbeResult) {
        let missing: Bool? =
            switch result {
            case .granted: false
            case .missing: true
            case .cannotVerify: nil
            }
        guard missing != fdaMissing else { return }
        fdaMissing = missing
        pushStatus()
    }
}
