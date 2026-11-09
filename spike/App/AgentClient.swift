import Foundation
import ServiceManagement

/// XPC client for the agent. Every call is a JSON request; replies arrive as JSON text.
final class AgentClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping @Sendable (String) -> Void) -> AgentXPC? {
        lock.withLock {
            if connection == nil {
                let c = NSXPCConnection(machServiceName: SpikeIDs.agentLabel, options: [])
                c.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
                c.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
                c.resume()
                connection = c
            }
            return connection?.remoteObjectProxyWithErrorHandler { error in
                onError(#"{"xpcError":"\#(error.localizedDescription)"}"#)
            } as? AgentXPC
        }
    }

    /// Sends a request and returns the reply, or an {"xpcError": …} object after `timeout`.
    func send(json requestJSON: String, timeout: TimeInterval = 600) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = Once(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(#"{"xpcError":"timed out after \#(Int(timeout))s"}"#)
            }
            guard let agent = proxy(onError: { once.resume($0) }) else {
                once.resume(#"{"xpcError":"no proxy"}"#); return
            }
            agent.perform(requestJSON) { once.resume($0) }
        }
    }

    func reset() { lock.withLock { connection?.invalidate(); connection = nil } }

    static var service: SMAppService { SMAppService.agent(plistName: SpikeIDs.agentPlistName) }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}

/// Resumes a continuation exactly once (reply, error handler and timeout all race).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func resume(_ value: String) {
        let c: CheckedContinuation<String, Never>? = lock.withLock { defer { continuation = nil }; return continuation }
        c?.resume(returning: value)
    }
}
