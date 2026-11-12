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

/// Plan lines are shown only while healthy: in any other state the last status may be stale.
public func showsPlanLines(_ health: AgentHealthState) -> Bool { health == .healthy }

/// "Back Up Now" only while healthy: a draining agent refuses it.
public func allowsBackUpNow(_ health: AgentHealthState) -> Bool { health == .healthy }

/// The menu bar icon's states, least to most severe: the worst state across all plans is the largest
/// (`max`). Error is the only filled icon.
public enum StatusIconState: Sendable, Comparable {
    case ok
    case backingUp
    case paused
    case warning
    case error
}

/// The menu bar icon (spec §6.2, anti-goal 3: never green over a fault).
/// - error: the agent unreachable, switched off or broken; a config error; a stopped plan; a failure alert
/// - warning: a skipped plan, or an alert that monitoring or recent success is missing
/// - ok otherwise, and while checking or updating, when the status is from before the change
public func statusIconState(health: AgentHealthState, status: AgentStatus?) -> StatusIconState {
    switch health {
    case .switchedOff, .notRunning, .damaged, .failed: return .error
    case .checking, .updating, .waitingForUpdate: return .ok
    case .healthy: break
    }
    guard let status else { return .ok }
    if status.configError != nil { return .error }
    let errorAlerts: Set<AlertCondition> = [.backupFailed, .checkFailed, .fullDiskAccessMissing, .configurationError]
    let warningAlerts: Set<AlertCondition> = [.notificationsOff, .checkInRejected, .noRecentSuccess]
    var warning = false
    for plan in status.plans {
        if case .stopped = plan.phase { return .error }
        if !errorAlerts.isDisjoint(with: plan.alerts) { return .error }
        if case .skipped = plan.phase { warning = true }
        if !warningAlerts.isDisjoint(with: plan.alerts) { warning = true }
    }
    return warning ? .warning : .ok
}
