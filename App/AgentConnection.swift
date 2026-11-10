import Foundation
import RestoreyCore
import Synchronization

/// Why a call to the agent didn't produce a reply.
enum AgentCallError: Error, Equatable, CustomStringConvertible {
    /// The XPC connection failed or the agent didn't answer in time.
    case unreachable(String)
    /// The agent answered with its own sentence, shown as is.
    case refused(String)
    /// The reply couldn't be decoded.
    case badReply(String)

    var description: String {
        switch self {
        case .unreachable(let detail): "Restorey couldn't reach its background agent (\(detail))."
        case .refused(let message): message
        case .badReply(let detail): "Restorey's background agent sent a reply it couldn't read (\(detail))."
        }
    }
}

/// The XPC client for the agent (ported from the spike's `AgentClient`). It exports an `AgentClientXPC`
/// object so the agent can push status, and after an interruption or invalidation it fetches `status`
/// again with back-off (1 s doubling to 60 s), which reconnects and resubscribes.
@MainActor
final class AgentConnection {
    private let serviceName: String
    private let receiver: StatusReceiver
    private var connection: NSXPCConnection?
    private var resubscribe: Task<Void, Never>?

    /// Every status the agent sends: pushes, `status` replies and the replies to mutating calls.
    var onStatus: ((AgentStatus) -> Void)?

    init(installed: InstalledCopy, identity: Identity) {
        _ = installed
        serviceName = identity.agentLabel
        receiver = StatusReceiver()
        receiver.connection = self
    }

    // MARK: Calls

    func hello(_ request: HelloRequest) async -> Result<HelloReply, AgentCallError> {
        guard let data = try? XPCCoding.encode(request) else { return .failure(.badReply("hello request")) }
        return await call(HelloReply.self, timeout: .seconds(5)) { $0.hello(data, withReply: $1) }
    }

    func status() async -> Result<AgentStatus, AgentCallError> {
        await statusCall(timeout: .seconds(10)) { $0.status(withReply: $1) }
    }

    /// No timeout: the agent replies once no run is in flight, which can take hours on a first backup.
    func prepareForRestart() async -> Result<DrainReply, AgentCallError> {
        await call(DrainReply.self, timeout: nil) { $0.prepareForRestart(withReply: $1) }
    }

    /// Drains like `prepareForRestart`, but the agent stays up so `unregister()` stops this process. No
    /// timeout, for the same reason.
    func prepareForReregistration() async -> Result<DrainReply, AgentCallError> {
        await call(DrainReply.self, timeout: nil) { $0.prepareForReregistration(withReply: $1) }
    }

    func savePlan(_ request: SavePlanRequest) async -> Result<AgentStatus, AgentCallError> {
        guard let data = try? XPCCoding.encode(request) else { return .failure(.badReply("save request")) }
        return await statusCall(timeout: .seconds(60)) { $0.savePlan(data, withReply: $1) }
    }

    func backUpNow(_ planID: UUID?) async -> Result<AgentStatus, AgentCallError> {
        await statusCall(timeout: .seconds(60)) { $0.backUpNow(planID?.uuidString, withReply: $1) }
    }

    func pause(_ planID: UUID) async -> Result<AgentStatus, AgentCallError> {
        await statusCall(timeout: .seconds(60)) { $0.pause(planID.uuidString, withReply: $1) }
    }

    func resume(_ planID: UUID) async -> Result<AgentStatus, AgentCallError> {
        await statusCall(timeout: .seconds(60)) { $0.resume(planID.uuidString, withReply: $1) }
    }

    func confirmRecoveryKit(_ planID: UUID) async -> Result<AgentStatus, AgentCallError> {
        await statusCall(timeout: .seconds(60)) { $0.confirmRecoveryKit(planID.uuidString, withReply: $1) }
    }

    /// restic retries an unreachable backend for up to 15 minutes, so these allow 20.
    func createRepository(_ planID: UUID) async -> Result<AgentStatus, AgentCallError> {
        await statusCall(timeout: .seconds(1200)) { $0.createRepository(planID.uuidString, withReply: $1) }
    }

    func adopt(_ planID: UUID) async -> Result<AdoptReport, AgentCallError> {
        await call(AdoptReport.self, timeout: .seconds(1200)) { $0.adopt(planID.uuidString, withReply: $1) }
    }

    /// Waits for the user to answer the agent's prompt.
    func requestNotificationPermission() async -> Result<NotificationPermissionReply, AgentCallError> {
        await call(NotificationPermissionReply.self, timeout: .seconds(600)) {
            $0.requestNotificationPermission(withReply: $1)
        }
    }

    /// Drops the connection, e.g. after `unregister()`; the next call makes a new one.
    /// The supervisor fetches `status` again once the agent is healthy (`shouldRefetchStatus`), which
    /// resubscribes, so a pending back-off retry is no longer needed.
    func reset() {
        resubscribe?.cancel()
        resubscribe = nil
        connection?.invalidate()
        connection = nil
    }

    // MARK: Plumbing

    private func statusCall(
        timeout: Duration?, _ send: (AgentXPC, @escaping @Sendable (Data?, String?) -> Void) -> Void
    ) async -> Result<AgentStatus, AgentCallError> {
        let result = await call(AgentStatus.self, timeout: timeout, send)
        if case .success(let status) = result { onStatus?(status) }
        return result
    }

    /// Makes one call. Exactly one of the reply, the XPC error handler and the timeout resolves it.
    private func call<T: Decodable & Sendable>(
        _ type: T.Type, timeout: Duration?,
        _ send: (AgentXPC, @escaping @Sendable (Data?, String?) -> Void) -> Void
    ) async -> Result<T, AgentCallError> {
        let connection = current()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, AgentCallError>, Never>) in
            let once = Once(continuation)
            if let timeout {
                once.timer = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    once.resume(.failure(.unreachable("no answer within \(timeout.components.seconds) s")))
                }
            }
            // Every closure handed to XPC is @Sendable, so it is nonisolated: XPC calls it on its own queue.
            // A plain closure written here would inherit the main actor, and the Swift 6 runtime traps when
            // XPC calls it off the main queue (the crash in fix round 3).
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(.failure(.unreachable(error.localizedDescription)))
            }
            guard let agent = proxy as? AgentXPC else {
                once.resume(.failure(.unreachable("no proxy")))
                return
            }
            send(agent) { @Sendable data, error in
                if let data {
                    do {
                        once.resume(.success(try XPCCoding.decode(T.self, from: data)))
                    } catch {
                        once.resume(.failure(.badReply(String(describing: error))))
                    }
                } else {
                    once.resume(.failure(.refused(error ?? "Restorey's background agent gave no reason.")))
                }
            }
        }
    }

    private func current() -> NSXPCConnection {
        if let connection { return connection }
        let made = NSXPCConnection(machServiceName: serviceName, options: [])
        made.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
        made.exportedInterface = NSXPCInterface(with: AgentClientXPC.self)
        made.exportedObject = receiver
        let key = ObjectIdentifier(made)
        // @Sendable, so nonisolated (see `call`); they hop to the main queue themselves.
        made.interruptionHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost(key, invalidated: false) } }
        }
        made.invalidationHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost(key, invalidated: true) } }
        }
        made.resume()
        connection = made
        return made
    }

    /// An interruption keeps the connection (the next message reaches the restarted agent); an
    /// invalidation drops it. Either way the agent no longer knows about us, so fetch `status` again,
    /// which resubscribes to its pushes.
    private func lost(_ key: ObjectIdentifier, invalidated: Bool) {
        guard let connection, ObjectIdentifier(connection) == key else { return }
        if invalidated { self.connection = nil }
        guard resubscribe == nil else { return }
        resubscribe = Task { [weak self] in
            var delay = Duration.seconds(1)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self else { return }
                if case .success = await self.status() { break }
                delay = min(delay * 2, .seconds(60))
            }
            // A cancelled task was replaced (or dropped) by reset(); don't clear its successor.
            if !Task.isCancelled { self?.resubscribe = nil }
        }
    }

    fileprivate func received(_ status: AgentStatus) {
        onStatus?(status)
    }
}

/// The exported object the agent pushes `statusChanged` to. Called on an XPC queue; hops to the main
/// queue in arrival order.
private final class StatusReceiver: NSObject, AgentClientXPC, @unchecked Sendable {
    /// Set once, before the first connection is made; read only on the main actor.
    weak var connection: AgentConnection?

    /// Nonisolated (the class has no actor): XPC calls it on its own queue.
    nonisolated func statusChanged(_ status: Data) {
        guard let decoded = try? XPCCoding.decode(AgentStatus.self, from: status) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.connection?.received(decoded) }
        }
    }
}

/// Resumes a continuation exactly once: the reply, the error handler and the timeout all race.
private final class Once<T: Sendable>: Sendable {
    private let state: Mutex<(continuation: CheckedContinuation<T, Never>?, timer: Task<Void, Never>?)>

    init(_ continuation: CheckedContinuation<T, Never>) {
        state = Mutex((continuation, nil))
    }

    var timer: Task<Void, Never>? {
        get { state.withLock { $0.timer } }
        set { state.withLock { $0.timer = newValue } }
    }

    func resume(_ value: T) {
        let taken = state.withLock { state in
            defer { state = (nil, nil) }
            return state
        }
        taken.timer?.cancel()
        taken.continuation?.resume(returning: value)
    }
}
