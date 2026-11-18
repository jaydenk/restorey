import Foundation
import RestoreyCore
import Synchronization

/// Credentials Settings is checking before it saves them (`AgentState.probeRepository(_:candidates:)`), held in
/// memory for a plan only during the check's turn of the repository queue. While they are set the helper serves
/// them in place of the keychain's (`HelperResponder`), and the check's environment uses a typed environment value.
/// No other restic of the plan, or of its repository, runs during that turn, so only the check's restic gets them.
/// Never logged, never written anywhere.
///
/// Synchronous (a lock, not an actor), so the runner can clear them with `defer` however its turn ends.
public final class CandidateSecrets: Sendable {
    private struct Contents {
        var values: [UUID: [SecretKey: String]] = [:]
        var observer: (@Sendable (UUID, [SecretKey: String]?) -> Void)?
    }

    private let contents = Mutex(Contents())

    public init() {}

    /// Nil clears the plan's.
    public func set(_ secrets: [SecretKey: String]?, for planID: UUID) {
        let observer = contents.withLock { contents in
            contents.values[planID] = secrets
            return contents.observer
        }
        observer?(planID, secrets)
    }

    public func values(for planID: UUID) -> [SecretKey: String]? {
        contents.withLock { $0.values[planID] }
    }

    public func value(_ key: SecretKey, planID: UUID) -> String? {
        values(for: planID)?[key]
    }

    /// Called after every `set`. For tests whose helper script stands in for the agent's helper.
    func observe(_ observer: @escaping @Sendable (UUID, [SecretKey: String]?) -> Void) {
        contents.withLock { $0.observer = observer }
    }
}
