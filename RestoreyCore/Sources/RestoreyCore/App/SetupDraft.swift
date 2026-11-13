import Foundation

/// What the setup window holds while it is open: where setup is (`SetupProgress`, which is saved), the plan
/// being built, and the secrets typed into the current step. The secrets are transient (global constraints):
/// each step hands its secrets to the agent (and so the keychain) before it ends, so they go whenever the step
/// changes and when the window closes, and they never appear in a description or log.
public struct SetupDraft: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public private(set) var progress: SetupProgress
    /// The plan being built, from the storage step on. Holds no secrets (`Plan`). Saved to the agent at each
    /// step's Continue, so a setup resumed after a quit gets it back from the agent's status.
    public var plan: Plan?
    /// What the storage step's "Check" (or the password step's own probe) found at the plan's address. Not
    /// saved: a resumed password step probes again.
    public var probe: RepositoryProbe?
    public private(set) var secrets: [SecretKey: String] = [:]
    /// The values typed into the storage step's environment rows, by row: a row's name can still change, and its
    /// keychain name (`SecretKey.environment`) is only decided at "Check". Secrets, dropped like `secrets`.
    private var environmentValues: [UUID: String] = [:]

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

    public func environmentValue(_ row: UUID) -> String? { environmentValues[row] }

    /// Nil removes the value.
    public mutating func setEnvironmentValue(_ value: String?, for row: UUID) {
        environmentValues[row] = value
    }

    /// Moves to `step`. Leaving a step drops every secret it held.
    public mutating func go(to step: SetupStep) {
        guard step != progress.step else { return }
        secrets = [:]
        environmentValues = [:]
        progress.step = step
    }

    /// The plan's address changed: what was found, created or adopted at the old one no longer holds.
    public mutating func forgetRepository() {
        probe = nil
        progress.repositoryCreated = false
        progress.adoption = nil
    }

    /// "Create New Repository" succeeded.
    public mutating func setRepositoryCreated() {
        progress.repositoryCreated = true
    }

    /// `adopt` succeeded with `report`.
    public mutating func setAdoption(_ report: AdoptReport) {
        progress.adoption = report
    }

    /// The saved plan is gone (deleted elsewhere): setup starts again at the storage step, keeping only how it
    /// was opened and the Open at login choice.
    public mutating func forgetPlan() {
        plan = nil
        probe = nil
        secrets = [:]
        environmentValues = [:]
        progress = SetupProgress(
            planID: nil, step: .storage, addingPlan: progress.addingPlan, openAtLogin: progress.openAtLogin)
    }

    /// Records the plan the storage step's "Check" saved, so a quit after it resumes with that plan.
    public mutating func setPlanID(_ id: UUID?) {
        progress.planID = id
    }

    /// The recovery-kit step's "I've saved it somewhere other than this Mac" tick (`SetupProgress.kitSaved`).
    /// The agent's confirmation waits for Done (`SetupFlow`).
    public mutating func setKitSaved(_ saved: Bool) {
        progress.kitSaved = saved
    }

    /// Records the permissions step's "Open at login" switch, applied later by Continue.
    public mutating func setOpenAtLogin(_ on: Bool) {
        progress.openAtLogin = on
    }

    /// The window is closing: the secrets go; the progress stays for the next opening.
    public mutating func close() {
        secrets = [:]
        environmentValues = [:]
    }

    public var description: String {
        let accounts = secrets.keys.map(\.account).sorted().joined(separator: ", ")
        return "SetupDraft(step: \(progress.step.rawValue), plan: \(plan?.id.uuidString ?? "none"), secrets: [\(accounts)], "
            + "environment values: \(environmentValues.count))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "progress": progress, "plan": plan as Any, "secrets": secrets.keys.map(\.account).sorted(),
                "environmentValues": environmentValues.count,
            ],
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
