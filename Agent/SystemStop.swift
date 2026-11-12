import AgentCore
import Foundation
import Synchronization

/// Handles launchd's SIGTERM (logout, restart, shutdown; Ruling R67): `AgentState.stopForSystem`
/// interrupts the runs in flight so they end `.stoppedBySystem`, flushes what it can, then the agent
/// exits 0. A second SIGTERM, or one that arrives while a restart exit is already on its way, exits
/// nothing twice: `stopForSystem` says whether this call should exit.
final class SystemStop: Sendable {
    private struct Parts {
        var state: AgentState?
        var runner: PlanRunner?
    }

    private let parts = Mutex(Parts())

    /// The state, as soon as it exists.
    func attach(state: AgentState) {
        parts.withLock { $0.state = state }
    }

    /// The runner, as soon as it exists: recovery's unlocks run before it is attached to the state.
    func attach(runner: PlanRunner) {
        parts.withLock { $0.runner = runner }
    }

    func stop() {
        let (state, runner) = parts.withLock { ($0.state, $0.runner) }
        // Before the state exists nothing has started, so there is nothing to stop or save.
        guard let state else { exit(0) }
        Task {
            if await state.stopForSystem(runner: runner) { DispatchQueue.main.async { exit(0) } }
        }
    }
}
