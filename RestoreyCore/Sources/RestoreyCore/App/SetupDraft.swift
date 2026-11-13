import Foundation

/// What the setup window holds while it is open: where setup is (`SetupProgress`, which is saved), the plan
/// being built, and the secrets typed into the current step. The secrets are transient (global constraints):
/// each step hands its secrets to the agent (and so the keychain) before it ends, so they go whenever the step
/// changes and when the window closes, and they never appear in a description or log.
public struct SetupDraft: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public private(set) var progress: SetupProgress
    /// The plan being built, from the storage step on (Task 12). Holds no secrets (`Plan`).
    public var plan: Plan?
    public private(set) var secrets: [SecretKey: String] = [:]

    public init(progress: SetupProgress, plan: Plan? = nil) {
        self.progress = progress
        self.plan = plan
    }

    public var step: SetupStep { progress.step }

    public func secret(_ key: SecretKey) -> String? { secrets[key] }

    /// Nil removes the secret.
    public mutating func setSecret(_ value: String?, for key: SecretKey) {
        secrets[key] = value
    }

    /// Moves to `step`. Leaving a step drops every secret it held.
    public mutating func go(to step: SetupStep) {
        guard step != progress.step else { return }
        secrets = [:]
        progress.step = step
    }

    /// The window is closing: the secrets go; the progress stays for the next opening.
    public mutating func close() {
        secrets = [:]
    }

    public var description: String {
        let accounts = secrets.keys.map(\.account).sorted().joined(separator: ", ")
        return "SetupDraft(step: \(progress.step.rawValue), plan: \(plan?.id.uuidString ?? "none"), secrets: [\(accounts)])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["progress": progress, "plan": plan as Any, "secrets": secrets.keys.map(\.account).sorted()],
            displayStyle: .struct)
    }
}

extension SetupStep {
    /// The line above each screen, as the mockup numbers it: Move to Applications is part of step 1,
    /// Permissions. "+ Add plan…" runs storage to schedule, numbered from 1.
    public func heading(addingPlan: Bool) -> String {
        let numbered: [SetupStep] = addingPlan
            ? [.storage, .password, .recoveryKit, .sources, .schedule]
            : [.permissions, .storage, .password, .recoveryKit, .sources, .schedule]
        let shown: SetupStep = self == .moveToApplications ? .permissions : self
        guard let index = numbered.firstIndex(of: shown) else { return title }
        return "Step \(index + 1) of \(numbered.count) · \(title)"
    }

    public var title: String {
        switch self {
        case .moveToApplications, .permissions: "Permissions"
        case .storage: "Where backups go"
        case .password: "Repository password"
        case .recoveryKit: "Recovery kit"
        case .sources: "What to back up"
        case .schedule: "Schedule"
        case .done: "Done"
        }
    }
}
