import AgentCore
import Foundation
import RestoreyCore
import UserNotifications

/// The thin `@objc` adapter from XPC to `AgentState`: it decodes each request, calls the state, and
/// replies with JSON or an Australian English error. All logic lives in `AgentState` (AgentCore),
/// where it is tested without XPC.
final class AgentService: NSObject, AgentXPC, Sendable {
    private let state: AgentState
    private let log: AppLog
    /// Called once a drain has been replied to, to exit so launchd starts the new binary.
    private let afterDrain: @Sendable () -> Void

    init(state: AgentState, log: AppLog, afterDrain: @escaping @Sendable () -> Void) {
        self.state = state
        self.log = log
        self.afterDrain = afterDrain
    }

    // MARK: AgentXPC

    func hello(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Not logged: the app's heartbeat sends one every 10 s.
        respond(reply) { [state] in
            _ = try Self.decode(HelloRequest.self, from: request)
            let info = Bundle.main.infoDictionary ?? [:]
            return HelloReply(
                agentVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                agentBuild: info["CFBundleVersion"] as? String ?? "unknown",
                executablePath: Bundle.main.executableURL?.path ?? "unknown",
                draining: await state.isDraining,
                notificationsAuthorised: await Self.notificationsAuthorised())
        }
    }

    func status(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state] in await state.status() }
    }

    func savePlan(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let save = try Self.decode(SavePlanRequest.self, from: request)
            let status = try await state.savePlan(save)
            // The request's description names the secrets' keys, never their values.
            log.info("Saved \(save)")
            return status
        }
    }

    func deletePlan(_ id: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let status = try await state.deletePlan(try Self.planID(id))
            log.info("Deleted plan \(id)")
            return status
        }
    }

    func backUpNow(_ planID: String?, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let status = try await state.backUpNow(try planID.map(Self.planID))
            log.info("Back up now: \(planID.map { "plan \($0)" } ?? "every plan")")
            return status
        }
    }

    func pause(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let status = try await state.pause(try Self.planID(planID))
            log.info("Paused plan \(planID)")
            return status
        }
    }

    func resume(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let status = try await state.resume(try Self.planID(planID))
            log.info("Resumed plan \(planID)")
            return status
        }
    }

    func createRepository(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let status = try await state.createRepository(try Self.planID(planID))
            log.info("Created the repository for plan \(planID)")
            return status
        }
    }

    func adopt(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let report = try await state.adopt(try Self.planID(planID))
            log.info("Read \(report.snapshotCount) snapshots for plan \(planID) to adopt its repository")
            return report
        }
    }

    func confirmRecoveryKit(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [state, log] in
            let status = try await state.confirmRecoveryKit(try Self.planID(planID))
            log.info("Recovery details confirmed for plan \(planID)")
            return status
        }
    }

    func requestNotificationPermission(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply) { [log] in
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            log.info("Notification permission \(granted ? "granted" : "not granted")")
            return NotificationPermissionReply(granted: granted)
        }
    }

    func prepareForRestart(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task { [state, log, afterDrain] in
            log.info("Asked to restart: finishing any run in progress first")
            await state.prepareForRestart()
            log.info("No run in progress; exiting so launchd starts the agent again")
            do {
                reply(try XPCCoding.encode(DrainReply(drained: true)), nil)
            } catch {
                reply(nil, "Restorey's agent couldn't encode its reply: \(error.localizedDescription)")
            }
            afterDrain()
        }
    }

    // MARK: Helpers

    private func respond<T: Encodable & SendableMetatype>(
        _ reply: @escaping @Sendable (Data?, String?) -> Void,
        _ work: @escaping @Sendable () async throws -> T
    ) {
        Task { [log] in
            do {
                reply(try XPCCoding.encode(try await work()), nil)
            } catch let error as AgentError {
                reply(nil, error.message)
            } catch {
                log.error("Unexpected error handling an XPC request: \(error)")
                reply(nil, "Restorey's agent hit an unexpected error: \(error.localizedDescription)")
            }
        }
    }

    private static func planID(_ string: String) throws -> UUID {
        guard let id = UUID(uuidString: string) else {
            throw AgentError.invalidRequest("\"\(string)\" isn't a plan ID")
        }
        return id
    }

    /// The error names only the type and the coding path, never a value: a `SavePlanRequest` carries secrets.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try XPCCoding.decode(type, from: data)
        } catch let error as DecodingError {
            throw AgentError.invalidRequest("\(T.self) is malformed at \(Self.codingPath(of: error))")
        } catch {
            throw AgentError.invalidRequest("\(T.self) is malformed")
        }
    }

    private static func codingPath(of error: DecodingError) -> String {
        let path: [any CodingKey] =
            switch error {
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
                 .dataCorrupted(let context):
                context.codingPath
            @unknown default: []
            }
        return path.isEmpty ? "the top level" : path.map { $0.intValue.map(String.init) ?? $0.stringValue }
            .joined(separator: ".")
    }

    /// Nil until the user has been asked.
    private static func notificationsAuthorised() async -> Bool? {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: true
        case .denied: false
        case .notDetermined: nil
        @unknown default: nil
        }
    }
}
