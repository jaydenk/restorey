import AgentCore
import Foundation
import RestoreyCore

/// Serves `HelperXPC` on `Identity.helperServiceName` to the agent's own executable in helper mode
/// (`print-password`, `s3-credentials`). The listener's code requirement names the agent's bundle ID and
/// our team, so XPC checks every message's audit token before it reaches `HelperService`; only then is
/// the peer's pid read and handed to `HelperResponder`, which checks that its parent is a supervised
/// restic for the plan (spec §7, "Confused deputy").
final class HelperListener: NSObject, NSXPCListenerDelegate, Sendable {
    private let service: HelperService
    private let log: AppLog

    init(responder: HelperResponder, log: AppLog) {
        service = HelperService(responder: responder, log: log)
        self.log = log
    }

    /// Creates and resumes the listener. The caller keeps both the listener and this delegate alive.
    func listen(identity: Identity, team: String) -> NSXPCListener {
        let listener = NSXPCListener(machServiceName: identity.helperServiceName)
        listener.setConnectionCodeSigningRequirement(
            AgentListener.codeSigningRequirement(bundleID: identity.agentBundleID, team: team))
        listener.delegate = self
        listener.resume()
        log.info("Listening on \(identity.helperServiceName) for \(identity.agentBundleID) in helper mode")
        return listener
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// The `@objc` adapter from XPC to `HelperResponder`. Logs who was answered or refused and why, never a
/// secret.
private final class HelperService: NSObject, HelperXPC, Sendable {
    private let responder: HelperResponder
    private let log: AppLog

    init(responder: HelperResponder, log: AppLog) {
        self.responder = responder
        self.log = log
    }

    func secret(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Read while the message is being delivered, so this is the connection whose audit token just
        // passed the listener's code requirement.
        guard let connection = NSXPCConnection.current() else {
            log.error("Refused a helper request with no XPC connection")
            reply(nil, "Restorey couldn't identify the caller")
            return
        }
        let pid = connection.processIdentifier
        Task { [responder, log] in
            switch await responder.respond(to: request, callerPID: pid) {
            case .success(let payload):
                log.info("Answered a helper request from pid \(pid)")
                reply(payload, nil)
            case .failure(let refusal):
                log.error("Refused a helper request from pid \(pid): \(refusal)")
                reply(nil, "Restorey refused the request: \(refusal)")
            }
        }
    }
}
