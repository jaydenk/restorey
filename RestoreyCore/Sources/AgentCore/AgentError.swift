import RestoreyCore

/// Why the agent refused a request. `message` is the Australian English sentence the XPC reply carries.
public enum AgentError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `config.json` or `state.json` could not be read; `AgentStatus.configError` says why.
    case configUnavailable
    /// `prepareForRestart` was called; the agent is waiting to exit.
    case draining
    /// A re-registration drain was asked for while a restart drain is under way: the agent is about to
    /// exit on its own, so the app must not unregister the agent launchd starts next.
    case restarting
    case invalidPlan([PlanValidationError])
    case unknownPlan
    case planRunning(name: String)
    case alreadyRunning(name: String)
    /// `deletePlan` is removing the plan; no run may start on it.
    case planDeleting(name: String)
    /// A `SavePlanRequest` carried a secret keyed to another plan.
    case foreignSecret
    /// No `PlanRunner` is attached yet (the agent is still starting), so nothing can run.
    case runnerUnavailable
    /// A plan never backs up before the user confirms they saved its recovery kit (spec §7).
    case recoveryKitNotConfirmed(name: String)
    /// `createRepository` found a repository at the address; restic init never overwrites one.
    case repositoryAlreadyExists
    /// A restic action asked for by the app (create, adopt) failed. The text is already redacted.
    case operationFailed(String)
    /// Writing a store, the keychain or a file failed. The text names the step, never a secret.
    case storage(String)
    /// The XPC payload could not be decoded.
    case invalidRequest(String)

    public var message: String {
        switch self {
        case .configUnavailable: "Restorey can't change its settings until the problem with them is fixed"
        case .draining: "Restorey is finishing the current backup before updating the agent"
        case .restarting: "Restorey's agent is restarting to finish an update. Try again in a moment"
        case .invalidPlan(let errors):
            errors.map(Self.message(for:)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ". ")
        case .unknownPlan: "There's no plan with that ID"
        case .planRunning(let name): "\(name) is backing up. Wait for it to finish, then delete it"
        case .alreadyRunning(let name): "\(name) is already backing up"
        case .planDeleting(let name): "\(name) is being deleted"
        case .foreignSecret: "A secret in the request belongs to a different plan"
        case .runnerUnavailable: "Restorey's agent is still starting up. Try again in a moment"
        case .recoveryKitNotConfirmed(let name):
            "Confirm you've saved the recovery kit for \(name) before its first backup"
        case .repositoryAlreadyExists: "A repository already exists there"
        case .operationFailed(let detail): detail
        case .storage(let detail): detail
        case .invalidRequest(let detail): "Restorey couldn't read the request: \(detail)"
        }
    }

    public var description: String { message }

    static func message(for error: PlanValidationError) -> String {
        switch error {
        case .emptyHostLabel: "The host label can't be empty"
        case .noSources: "Choose at least one source folder"
        case .relativeSource: "Source folders must be absolute paths"
        case .intervalTooShort: "Backups can't run more often than every 5 minutes"
        case .invalidFileType(let entry):
            "\"\(entry)\" isn't a file type to exclude: give the extension alone, such as dmg, without a dot, slash or wildcard"
        }
    }
}
