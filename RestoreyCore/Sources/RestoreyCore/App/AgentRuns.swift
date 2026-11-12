import Foundation

/// Ruling R76: whether the app shows `status` in place of `current`. A status from an agent process already seen
/// replaced (a late reply from before an update or a re-registration) is dropped; otherwise `supersedes` decides.
public func shouldAccept(status: AgentStatus, current: AgentStatus?, retired: Set<UUID>) -> Bool {
    if let run = status.agentRun, retired.contains(run) { return false }
    return status.supersedes(current)
}

/// The agent processes the app has seen, by the `agentRun` each one stamps on its hellos and statuses. Each launch
/// of the agent has a new one, so a newer run seen in a hello or a status means the one before it has gone for
/// good, and anything it still sends is stale.
public struct AgentRunTracker: Sendable, Equatable {
    /// The newest run seen.
    public private(set) var current: UUID?
    /// Every run seen replaced. One per agent launch while the app runs, so it stays small.
    public private(set) var retired: Set<UUID> = []

    public init() {}

    /// A hello or an accepted status reported `run`. Nil (an agent older than run IDs) and a retired run change
    /// nothing.
    public mutating func observe(_ run: UUID?) {
        guard let run, run != current, !retired.contains(run) else { return }
        if let current { retired.insert(current) }
        current = run
    }

    public func shouldAccept(_ status: AgentStatus, over shown: AgentStatus?) -> Bool {
        RestoreyCore.shouldAccept(status: status, current: shown, retired: retired)
    }
}

/// The status the menu is built from. While healthy, only one fetched since the return to healthy
/// (`shouldRefetchStatus`), so lines from before a repair are never shown as live. In any other state the last one
/// received stands in: `MenuPresentation` uses it only for "Last known: …", the lines of a backup finishing before
/// an update, and R68's "(agent not answering)", never as current.
public func menuStatus(health: AgentHealthState, live: AgentStatus?, lastKnown: AgentStatus?) -> AgentStatus? {
    health == .healthy ? live : (live ?? lastKnown)
}
