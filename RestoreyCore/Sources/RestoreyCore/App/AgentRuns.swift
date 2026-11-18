import Foundation

/// Ruling R76: whether the app shows `status` in place of `current`. A status from an agent process already seen
/// replaced (a late reply from before an update or a re-registration) is dropped; otherwise `supersedes` decides.
public func shouldAccept(status: AgentStatus, current: AgentStatus?, retired: Set<UUID>) -> Bool {
    if let run = status.agentRun, retired.contains(run) { return false }
    return status.supersedes(current)
}

/// The agent processes the app has seen, by the `agentRun` each one stamps on its hellos and statuses. Each launch
/// of the agent has a new one, so a hello from a newer run means the one before it has gone for good, and anything
/// it still sends is stale.
///
/// Only hellos retire runs (fix round 1). Heartbeats are serialised, so their order is the order of the agent
/// processes; statuses aren't (a late reply can arrive at any time), and a late status from a run the app never
/// heard of would otherwise retire the live agent and freeze the menu.
public struct AgentRunTracker: Sendable, Equatable {
    /// The run of the latest hello, or of the first status while no hello has been answered.
    public private(set) var current: UUID?
    /// Every run seen replaced. One per agent launch while the app runs, so it stays small.
    public private(set) var retired: Set<UUID> = []

    public init() {}

    /// A hello reported `run`: a new run retires the current one. Nil (an agent older than run IDs) and a retired
    /// run change nothing.
    public mutating func helloReported(_ run: UUID?) {
        guard let run, run != current, !retired.contains(run) else { return }
        if let current { retired.insert(current) }
        current = run
    }

    /// A status from `run` was accepted. It names the current run only when none is known yet, and never retires.
    public mutating func statusAccepted(_ run: UUID?) {
        guard current == nil, let run, !retired.contains(run) else { return }
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
