import Foundation
import RestoreyCore
import Synchronization

/// Accepts XPC connections on the agent's Mach service (`Identity.agentLabel`) and pushes status to
/// every connected app. The listener only admits the app: its code signing requirement names the app's
/// bundle ID and our team (ported from the spike, docs/spike-findings.md).
final class AgentListener: NSObject, NSXPCListenerDelegate, Sendable {
    private let service: AgentService
    private let log: AppLog
    private let clients = ClientConnections()

    init(service: AgentService, log: AppLog) {
        self.service = service
        self.log = log
    }

    /// The requirement every connecting process must meet.
    static func codeSigningRequirement(appBundleID: String, team: String) -> String {
        "identifier \"\(appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team ID from the `RestoreyTeamID` Info.plist key (set from `DEVELOPMENT_TEAM`), or nil when it
    /// is missing or not ten upper-case letters and digits. Without it there is no listener: fail closed.
    static func teamID(in bundle: Bundle) -> String? {
        guard let team = bundle.object(forInfoDictionaryKey: "RestoreyTeamID") as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
        else { return nil }
        return team
    }

    /// Creates and resumes the listener. The caller keeps both the listener and this delegate alive
    /// (`NSXPCListener.delegate` is weak).
    func listen(identity: Identity, team: String) -> NSXPCListener {
        let listener = NSXPCListener(machServiceName: identity.agentLabel)
        listener.setConnectionCodeSigningRequirement(
            Self.codeSigningRequirement(appBundleID: identity.appBundleID, team: team))
        listener.delegate = self
        listener.resume()
        log.info("Listening on \(identity.agentLabel) for \(identity.appBundleID)")
        return listener
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AgentXPC.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: AgentClientXPC.self)
        let key = ObjectIdentifier(connection)
        let pid = connection.processIdentifier
        connection.invalidationHandler = { [clients, log] in
            clients.remove(key)
            log.info("App connection from pid \(pid) closed")
        }
        clients.insert(connection, for: key)
        connection.resume()
        log.info("Accepted an app connection from pid \(pid)")
        return true
    }

    /// Sends `status` to every connected app. An app that exports no `AgentClientXPC` object just
    /// gets nothing; a send that fails is ignored, since the next status supersedes it.
    func broadcast(_ status: AgentStatus) {
        let data: Data
        do {
            data = try XPCCoding.encode(status)
        } catch {
            log.error("Couldn't encode a status push: \(error)")
            return
        }
        clients.forEach { connection in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? AgentClientXPC
            proxy?.statusChanged(data)
        }
    }
}

/// The open app connections, keyed by identity.
private final class ClientConnections: Sendable {
    /// `NSXPCConnection` is thread-safe (Apple documents it as usable from any thread) but the SDK does
    /// not mark it `Sendable`, so it travels in this box. Every access is under the mutex.
    private struct Box: @unchecked Sendable { let connection: NSXPCConnection }

    private let connections = Mutex<[ObjectIdentifier: Box]>([:])

    func insert(_ connection: NSXPCConnection, for key: ObjectIdentifier) {
        let box = Box(connection: connection)
        connections.withLock { $0[key] = box }
    }

    func remove(_ key: ObjectIdentifier) {
        connections.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Copies the connections out under the lock and calls `body` after releasing it, so a slow or
    /// re-entrant XPC call never runs while the lock is held.
    func forEach(_ body: (NSXPCConnection) -> Void) {
        let boxes = connections.withLock { Array($0.values) }
        for box in boxes { body(box.connection) }
    }
}
