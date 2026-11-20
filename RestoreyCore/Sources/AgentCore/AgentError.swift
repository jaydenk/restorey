import Foundation
import RestoreyCore

/// Why the agent refused a request. `message` is the Australian English sentence the XPC reply carries.
public enum AgentError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `config.json` or `state.json` could not be read; `AgentStatus.configError` says why.
    case configUnavailable
    /// `prepareForRestart` was called; the agent is waiting to exit.
    case draining
    /// A re-registration drain was asked for while a restart drain or a system stop is under way: the agent
    /// is about to exit on its own, so the app must not unregister the agent launchd starts next.
    case restarting
    case invalidPlan([PlanValidationError])
    /// `saveNetworkSettings` was sent settings with these problems; nothing was saved.
    case invalidNetworkSettings([NetworkSettingsError])
    case unknownPlan
    case planRunning(name: String)
    case alreadyRunning(name: String)
    /// `deletePlan` is removing the plan; no run may start on it.
    case planDeleting(name: String)
    /// A `SavePlanRequest` carried a secret keyed to another plan.
    case foreignSecret
    /// No `PlanRunner` is attached yet (the agent is still starting), so nothing can run.
    case runnerUnavailable
    /// A plan never backs up before the user confirms they saved its recovery kit (spec §7). `setupFinished`: the
    /// plan's kit was confirmed once and a change to its repository or a secret asks for a new one (Ruling R28),
    /// which reads differently from a first backup (carry list).
    case recoveryKitNotConfirmed(name: String, setupFinished: Bool)
    /// `confirmRecoveryKit` was sent the digest of a kit that no longer matches the plan (Task 9): its repository, a
    /// key or the host label changed after the kit was shown. Nothing was confirmed.
    case recoveryKitChanged
    /// `createRepository` found a repository at the address; restic init never overwrites one.
    case repositoryAlreadyExists
    /// A restic action asked for by the app (create, adopt) failed. The text is already redacted.
    case operationFailed(String)
    /// Writing a store, the keychain or a file failed. The text names the step, never a secret.
    case storage(String)
    /// The XPC payload could not be decoded.
    case invalidRequest(String)
    /// `pause` was sent a length that isn't one of `PauseLength`'s cases (an app and agent from different builds).
    case unknownPauseLength

    public var message: String {
        switch self {
        case .configUnavailable: "Restorey can’t change its settings until the problem with them is fixed"
        case .draining: "Restorey is finishing the current backup before updating"
        case .restarting: "Restorey is restarting to finish an update. Try again in a moment"
        case .invalidPlan(let errors):
            errors.map(\.message).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ". ")
        case .invalidNetworkSettings(let errors): errors.map(\.message).joined(separator: ". ")
        case .unknownPlan: "There’s no plan with that ID"
        case .planRunning(let name): "\(name) is backing up. Wait for it to finish, then delete it"
        case .alreadyRunning(let name): "\(name) is already backing up"
        case .planDeleting(let name): "\(name) is being deleted"
        case .foreignSecret: "A secret in the request belongs to a different plan"
        case .runnerUnavailable: "Restorey is still starting up. Try again in a moment"
        case .recoveryKitNotConfirmed(let name, setupFinished: false):
            "Confirm you’ve saved the recovery kit for \(name) before its first backup"
        case .recoveryKitNotConfirmed(let name, setupFinished: true):
            "Save a new recovery kit for \(name) — the saved one has the old keys"
        // Two sentences, so it keeps its closing stop; the app recognises it to show the new kit.
        case .recoveryKitChanged: RecoveryKitDocument.detailsChangedRefusal
        case .repositoryAlreadyExists: "A repository already exists there"
        case .operationFailed(let detail): detail
        case .storage(let detail): detail
        // Never joined with another message, and shown as it is (the menu's alert), so it keeps its closing stop.
        case .unknownPauseLength: "Restorey can’t pause for that long. Choose 1 hour, 4 hours or until tomorrow."
        case .invalidRequest(let detail): "Restorey couldn’t read the request: \(detail)"
        }
    }

    public var description: String { message }
}

extension PauseRequest {
    /// Reads `pause`'s XPC payload. A length that isn't one of `PauseLength`'s cases is refused with its own
    /// sentence; any other fault is the generic `invalidRequest`, naming only the type and the coding path.
    public static func decoded(from data: Data) throws -> PauseRequest {
        do {
            return try XPCCoding.decode(PauseRequest.self, from: data)
        } catch let DecodingError.dataCorrupted(context) where context.codingPath.last?.stringValue == "length" {
            throw AgentError.unknownPauseLength
        } catch let error as DecodingError {
            let path: [any CodingKey] =
                switch error {
                case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
                     .dataCorrupted(let context):
                    context.codingPath
                @unknown default: []
                }
            let at = path.isEmpty ? "the top level" : path.map(\.stringValue).joined(separator: ".")
            throw AgentError.invalidRequest("PauseRequest is malformed at \(at)")
        } catch {
            throw AgentError.invalidRequest("PauseRequest is malformed")
        }
    }
}
