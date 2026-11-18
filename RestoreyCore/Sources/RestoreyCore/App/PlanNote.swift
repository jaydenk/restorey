import Foundation

/// The note under a plan's name in Settings' sidebar, and the stop shown on the plan's page (UI design §6.2; live
/// finding 3, build 812). The words are the menu's: "Setup not finished", "New recovery kit needed", and for a plan
/// the agent has stopped, "Stopped" with its reason (`MenuPresentation`'s plan line).
public struct PlanNote: Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        case warning
        case error
    }

    public var title: String
    /// The agent's reason, for a stop.
    public var detail: String?
    public var level: Level

    public init(title: String, detail: String?, level: Level) {
        self.title = title
        self.detail = detail
        self.level = level
    }

    /// One line for the sidebar. An unfinished plan has nothing else to say yet; otherwise a stop comes before a new
    /// kit, since backups can't run until it is fixed (a wrong password, say), and the kit is confirmed after.
    public static func sidebar(_ status: PlanStatus) -> PlanNote? {
        if status.setupState == .unfinished { return PlanNote(title: "Setup not finished", detail: nil, level: .warning) }
        if let stop = stop(status) { return stop }
        if status.setupState == .needsNewKit {
            return PlanNote(title: "New recovery kit needed", detail: nil, level: .warning)
        }
        return nil
    }

    /// The agent stopped the plan: "Stopped" and why, until the cause is fixed.
    public static func stop(_ status: PlanStatus) -> PlanNote? {
        guard case .stopped(let reason) = status.phase else { return nil }
        return PlanNote(title: "Stopped", detail: reason, level: .error)
    }
}
