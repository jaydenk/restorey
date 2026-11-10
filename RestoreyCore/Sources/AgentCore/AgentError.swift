import RestoreyCore

/// Why the agent refused a request. `message` is the Australian English sentence the XPC reply carries.
public enum AgentError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `config.json` or `state.json` could not be read; `AgentStatus.configError` says why.
    case configUnavailable
    /// `prepareForRestart` was called; the agent is waiting to exit.
    case draining
    case invalidPlan([PlanValidationError])
    case unknownPlan
    case planRunning(name: String)
    case alreadyRunning(name: String)
    /// `deletePlan` is removing the plan; no run may start on it.
    case planDeleting(name: String)
    /// A `SavePlanRequest` carried a secret keyed to another plan.
    case foreignSecret
    /// Implemented by a later task (backups, repository creation and adoption arrive with the runner).
    case notYetAvailable
    /// Writing a store, the keychain or a file failed. The text names the step, never a secret.
    case storage(String)
    /// The XPC payload could not be decoded.
    case invalidRequest(String)

    public var message: String {
        switch self {
        case .configUnavailable: "Restorey can't change its settings until the problem with them is fixed"
        case .draining: "Restorey is finishing the current backup before updating the agent"
        case .invalidPlan(let errors):
            errors.map(Self.message(for:)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ". ")
        case .unknownPlan: "There's no plan with that ID"
        case .planRunning(let name): "\(name) is backing up. Wait for it to finish, then delete it"
        case .alreadyRunning(let name): "\(name) is already backing up"
        case .planDeleting(let name): "\(name) is being deleted"
        case .foreignSecret: "A secret in the request belongs to a different plan"
        case .notYetAvailable: "That isn't available in this build of Restorey yet"
        case .storage(let detail): detail
        case .invalidRequest(let detail): "Restorey couldn't read the request: \(detail)"
        }
    }

    public var description: String { message }

    private static func message(for error: PlanValidationError) -> String {
        switch error {
        case .emptyHostLabel: "The host label can't be empty"
        case .noSources: "Choose at least one source folder"
        case .relativeSource: "Source folders must be absolute paths"
        case .intervalTooShort: "Backups can't run more often than every 5 minutes"
        }
    }
}
