import Foundation
import RestoreyCore

/// Posts the agent's notifications. The agent's `Notifier` wraps `UNUserNotificationCenter`; the tests
/// use a fake.
public protocol AlertNotifying: Sendable {
    /// True when the agent may post, false when the user said no, nil when they haven't been asked.
    func authorisationStatus() async -> Bool?
    /// Hands the notification to the system. Throws if it was refused.
    func post(_ alert: AlertContent) async throws
}

/// The notification for one raised condition of one plan, in Australian English.
///
/// `identifier` is per plan and condition, so a re-notification replaces the banner before it;
/// `threadIdentifier` is per plan, so a plan's alerts group together. Conditions that belong to the
/// whole agent rather than one plan (Full Disk Access, unreadable settings) use `alert.agent.<name>`
/// and the thread `agent`, so every plan shares one banner.
public struct AlertContent: Sendable, Equatable {
    public var identifier: String
    public var threadIdentifier: String
    public var title: String
    public var body: String

    static let agentThread = "agent"

    /// The one notification for an agent whose `config.json` or `state.json` can't be read: no plan runs.
    public static func loadError(_ message: String) -> AlertContent {
        AlertContent(
            identifier: "alert.agent.loadError", threadIdentifier: agentThread,
            title: "Restorey has stopped — its settings can't be read", body: message)
    }

    private init(identifier: String, threadIdentifier: String, title: String, body: String) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.title = title
        self.body = body
    }

    /// Nil for `notificationsOff`, which can't be delivered as a notification.
    /// - Parameter checkInStatus: the HTTP status that raised `checkInRejected`, if the agent still knows it.
    public init?(
        condition: AlertCondition, plan: Plan, history: PlanRunHistory, now: Date, checkInStatus: Int? = nil
    ) {
        let name = plan.name
        var agentWide = false
        switch condition {
        case .backupFailed:
            title = "Backup failed — \(name)"
            body = Self.reason(of: .backup, in: history) ?? "The last backup didn't finish."
        case .checkFailed:
            title = "Repository check failed — \(name)"
            body = Self.reason(of: .check, in: history) ?? "restic found a problem when it checked the repository."
        case .checkInRejected:
            title = "Check-in URL rejected — \(name)"
            let answer = checkInStatus.map { "returned HTTP \($0)" } ?? "rejected the last ping"
            body = "The monitoring service \(answer), so it won't alert you if backups stop. Check the URL in this plan's settings."
        case .configurationError:
            title = "\(name) has stopped — \(history.stoppedReason ?? "a setting needs fixing")"
            body = "Backups of this plan won't run until it's fixed in Restorey."
        case .fullDiskAccessMissing:
            title = "Full Disk Access is missing — Restorey can't read your files"
            body = "Backups can't run until Restorey is turned on in System Settings › Privacy & Security › Full Disk Access."
            agentWide = true
        case .noRecentSuccess:
            let reference = history.lastSuccessAt ?? plan.createdAt
            let days = max(plan.noSuccessAlertDays, Int(now.timeIntervalSince(reference) / 86_400))
            let span = days == 1 ? "1 day" : "\(days) days"
            title = "No backup in \(span) — \(name)"
            body = history.lastSuccessAt == nil
                ? "This plan hasn't finished a backup since it was set up. Open Restorey to see why."
                : "This plan hasn't finished a backup for \(span). Open Restorey to see why."
        case .notificationsOff:
            return nil
        }
        identifier = agentWide ? "alert.agent.\(condition.rawValue)" : "alert.\(plan.id.uuidString).\(condition.rawValue)"
        threadIdentifier = agentWide ? Self.agentThread : "plan.\(plan.id.uuidString)"
    }

    /// Why the newest failed `operation` failed, as the runner explains it.
    private static func reason(of operation: ResticOperation, in history: PlanRunHistory) -> String? {
        guard let record = history.recent.first(where: { $0.operation == operation && $0.outcome.isFailure }) else {
            return nil
        }
        let reason = PlanRunner.explain(record.outcome, stoppedReason: nil)
        return reason.isEmpty ? nil : reason
    }
}

extension RunOutcome {
    fileprivate var isFailure: Bool {
        switch self {
        case .failed, .interrupted, .wrongPassword, .repositoryMissing, .credentialsUnavailable: true
        default: false
        }
    }
}
