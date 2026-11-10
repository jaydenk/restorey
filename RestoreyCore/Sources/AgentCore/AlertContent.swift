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
/// `threadIdentifier` is per plan, so a plan's alerts group together.
public struct AlertContent: Sendable, Equatable {
    public var identifier: String
    public var threadIdentifier: String
    public var title: String
    public var body: String

    /// Nil for `notificationsOff`, which can't be delivered as a notification.
    public init?(condition: AlertCondition, plan: Plan, history: PlanRunHistory, now: Date) {
        let name = plan.name
        switch condition {
        case .backupFailed:
            title = "Backup failed — \(name)"
            body = Self.reason(of: .backup, in: history) ?? "The last backup didn't finish."
        case .checkFailed:
            title = "Repository check failed — \(name)"
            body = Self.reason(of: .check, in: history) ?? "restic found a problem when it checked the repository."
        case .configurationError:
            title = "\(name) has stopped — \(history.stoppedReason ?? "a setting needs fixing")"
            body = "Backups of this plan won't run until it's fixed in Restorey."
        case .fullDiskAccessMissing:
            title = "Full Disk Access is missing — Restorey can't read your files"
            body = "\(name) can't back up until Restorey is turned on in System Settings › Privacy & Security › Full Disk Access."
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
        identifier = "alert.\(plan.id.uuidString).\(condition.rawValue)"
        threadIdentifier = "plan.\(plan.id.uuidString)"
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
