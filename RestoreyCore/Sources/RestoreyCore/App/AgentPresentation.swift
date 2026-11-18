import Foundation

/// What the app knows about the agent, for display. The app's supervisor moves between these.
public enum AgentHealthState: Sendable, Equatable {
    case checking
    case healthy
    /// The app asked for a drain: "Finishing the current backup before updating the agent".
    case updating
    /// The agent was already draining: "Updating the background agent…".
    case waitingForUpdate
    case switchedOff
    /// `reachable` when the agent answers but a repair didn't fix it.
    case notRunning(reachable: Bool)
    /// The app's own bundle is missing the agent's plist: "Restorey's installation is damaged — reinstall it
    /// from the download". No repair is offered, since none can help.
    case damaged
    /// Registering failed; the sentence is shown as is.
    case failed(String)
}

/// Fetch `status` afresh on every transition into `.healthy`. Lines from before a re-register, a drain or
/// an outage are then never shown as live, even if the connection was reset and no push arrived.
public func shouldRefetchStatus(previous: AgentHealthState, next: AgentHealthState) -> Bool {
    next == .healthy && previous != .healthy
}

/// The menu bar icon's states, least to most severe: the worst state across all plans is the largest
/// (`max`). Error is the only filled icon. `MenuPresentation.make` is the only thing that decides it.
public enum StatusIconState: Sendable, Comparable {
    case ok
    case backingUp
    case paused
    case warning
    case error
}
