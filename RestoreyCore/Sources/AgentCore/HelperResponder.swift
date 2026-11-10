import Foundation
import RestoreyCore

/// The agent's side of a helper request: decode, authorise, read the keychain, build the reply.
/// `HelperListener` (in the agent) is a thin XPC adapter over this.
///
/// Checks run in this order, and nothing touches the keychain until all of them pass: the request
/// decodes, its plan ID is a UUID, the caller's parent is a restic supervised for that plan
/// (`authoriseHelper`), and the plan is configured. A keychain read that fails, or finds no item, is
/// an error reply and is recorded with `AgentState.noteHelperFailure`, because restic itself only
/// reports "no credentials found" or a wrong password.
public struct HelperResponder: Sendable {
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case malformedRequest
        case invalidPlanID
        /// The caller's parent is not a restic the agent is supervising for that plan.
        case notSupervised
        case unknownPlan
        /// The keychain read failed or found nothing. The reason names the account, never a value.
        case secretUnavailable(String)

        public var description: String {
            switch self {
            case .malformedRequest: "the request couldn't be read"
            case .invalidPlanID: "the plan ID isn't a UUID"
            case .notSupervised: "the caller wasn't started by a restic run Restorey is supervising for that plan"
            case .unknownPlan: "there's no plan with that ID"
            case .secretUnavailable(let reason): reason
            }
        }
    }

    private let state: AgentState
    private let secrets: any SecretStore
    private let supervised: SupervisedProcesses
    private let parentOf: @Sendable (pid_t) -> pid_t?
    private let now: @Sendable () -> Date

    public init(
        state: AgentState, secrets: any SecretStore, supervised: SupervisedProcesses,
        parentOf: @escaping @Sendable (pid_t) -> pid_t? = parentPID(of:),
        now: @escaping @Sendable () -> Date
    ) {
        self.state = state
        self.secrets = secrets
        self.supervised = supervised
        self.parentOf = parentOf
        self.now = now
    }

    /// - Parameter callerPID: the XPC peer's pid, read only after its code requirement passed.
    public func respond(to data: Data, callerPID: pid_t) async -> Result<Data, Refusal> {
        guard let request = try? XPCCoding.decode(HelperRequest.self, from: data) else {
            return .failure(.malformedRequest)
        }
        guard let planID = UUID(uuidString: request.planID) else { return .failure(.invalidPlanID) }
        guard await authoriseHelper(callerPID: callerPID, planID: planID, parentOf: parentOf, supervised: supervised)
        else { return .failure(.notSupervised) }
        guard await state.isConfiguredPlan(planID) else { return .failure(.unknownPlan) }

        let result = Result { () throws(Refusal) -> Data in
            switch request.kind {
            case .repositoryPassword:
                return Data(try read(.repositoryPassword(planID)).utf8)
            case .s3Credentials:
                let keyID = try read(.s3AccessKeyID(planID))
                let secret = try read(.s3SecretAccessKey(planID))
                do {
                    return try makeCredentialProcessJSON(accessKeyID: keyID, secret: secret, now: now())
                } catch {
                    throw .secretUnavailable("Restorey couldn't encode the S3 credentials")
                }
            }
        }
        if case .failure(.secretUnavailable(let reason)) = result {
            await state.noteHelperFailure(planID: planID, reason: reason)
        }
        return result
    }

    private func read(_ key: SecretKey) throws(Refusal) -> String {
        let value: String?
        do {
            value = try secrets.read(key)
        } catch {
            throw .secretUnavailable("Restorey couldn't read \(key.account) from the Keychain: \(error)")
        }
        guard let value else { throw .secretUnavailable("\(key.account) isn't in the Keychain") }
        return value
    }
}
