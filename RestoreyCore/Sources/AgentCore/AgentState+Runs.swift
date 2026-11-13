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
    /// schedule but not the pre-run conditions. The reply shows the plan running. A refusal is written to
    /// `agent.log` as well as returned (final review M5): a Back Up Now that did nothing is otherwise
    /// invisible. The reasons never name a secret. A plan already backing up is not a refusal: the reply says
    /// so (`BackUpNowReply.alreadyRunning`).
    public func backUpNow(_ id: UUID?) async throws -> BackUpNowReply {
        do {
            try requireRunnable(id)
            return try await requireRunner().backUpNow(id)
        } catch let error as AgentError {
            agentLog("Refused Back Up Now of \(id.map { "plan \($0.uuidString)" } ?? "every plan"): \(error.message)")
            throw error
        }
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

    /// What is at the plan's repository address: nothing, or a repository its password opens (Ruling P2-2).
    /// Setup's "Check" calls it after saving the plan, so it runs before the recovery kit is confirmed.
    public func probeRepository(_ id: UUID) async throws -> RepositoryProbe {
        try requireRunnable(id)
        return try await requireRunner().probeRepository(planID: id)
    }

    /// Runs the Full Disk Access probe now and pushes the status (Ruling P2-11). Changes no file, so it is
    /// answered while draining and in the config-error state (where `fdaMissing` stays nil).
    public func probeFullDiskAccess() async throws -> AgentStatus {
        try await requireRunner().probeFullDiskAccess()
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

    /// Records the latest Full Disk Access probe for `AgentStatus.fdaMissing`, and pushes the status when
    /// it changed, or always with `pushingAlways`.
    @discardableResult
    func noteFullDiskAccess(_ result: FDAProbeResult, pushingAlways: Bool = false) -> AgentStatus {
        let missing: Bool? =
            switch result {
            case .granted: false
            case .missing: true
            case .cannotVerify: nil
            }
        guard missing != fdaMissing || pushingAlways else { return status() }
        fdaMissing = missing
        return pushStatus()
    }
}
