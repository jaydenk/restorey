import AgentCore
import Foundation
import RestoreyCore

/// The thin `@objc` adapter from XPC to `AgentState`: it decodes each request, calls the state, and
/// replies with JSON or an Australian English error. All logic lives in `AgentState` (AgentCore),
/// where it is tested without XPC.
final class AgentService: NSObject, AgentXPC, Sendable {
    private let state: AgentState
    private let log: AppLog
    private let notifier: Notifier
    /// `ExecutableFingerprint` of the binary at launch, reported in `hello`.
    private let executableFingerprint: String?
    /// Called after a change that can make a plan due now: a save, a recovery kit confirmation, a resume.
    private let plansChanged: @Sendable () -> Void

    init(
        state: AgentState, log: AppLog, notifier: Notifier, executableFingerprint: String?,
        plansChanged: @escaping @Sendable () -> Void
    ) {
        self.executableFingerprint = executableFingerprint
        self.state = state
        self.log = log
        self.notifier = notifier
        self.plansChanged = plansChanged
    }

    // MARK: AgentXPC

    func hello(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Not logged: the app's heartbeat sends one every 10 s. Built in process from what the agent holds,
        // never by asking the notification centre (Ruling R68): a hung usernoted must not make the app
        // think the agent is dead and unregister it mid-backup.
        respond(reply, "hello") { [state, executableFingerprint] in
            _ = try Self.decode(HelloRequest.self, from: request)
            let info = Bundle.main.infoDictionary ?? [:]
            return await state.helloReply(
                agentVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                agentBuild: info["CFBundleVersion"] as? String ?? "unknown",
                executablePath: Bundle.main.executableURL?.path ?? "unknown",
                executableFingerprint: executableFingerprint)
        }
    }

    func status(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "status") { [state] in await state.status() }
    }

    func savePlan(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "savePlan") { [state, log, plansChanged] in
            let save = try Self.decode(SavePlanRequest.self, from: request)
            let status = try await state.savePlan(save)
            // The request's description names the secrets' keys, never their values.
            log.info("Saved \(save)")
            plansChanged()
            return status
        }
    }

    func deletePlan(_ id: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "deletePlan") { [state, log] in
            let status = try await state.deletePlan(try Self.planID(id))
            log.info("Deleted plan \(id)")
            return status
        }
    }

    func backUpNow(_ planID: String?, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "Back Up Now") { [state, log] in
            let status = try await state.backUpNow(try planID.map(Self.planID))
            log.info("Back up now: \(planID.map { "plan \($0)" } ?? "every plan")")
            return status
        }
    }

    func pause(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "pause") { [state, log] in
            let status = try await state.pause(try Self.planID(planID))
            log.info("Paused plan \(planID)")
            return status
        }
    }

    func resume(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "resume") { [state, log, plansChanged] in
            let status = try await state.resume(try Self.planID(planID))
            log.info("Resumed plan \(planID)")
            plansChanged()
            return status
        }
    }

    func createRepository(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "createRepository") { [state, log] in
            let status = try await state.createRepository(try Self.planID(planID))
            log.info("Created the repository for plan \(planID)")
            return status
        }
    }

    func adopt(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "adopt") { [state, log] in
            let report = try await state.adopt(try Self.planID(planID))
            log.info("Read \(report.snapshotCount) snapshots for plan \(planID) to adopt its repository")
            return report
        }
    }

    func confirmRecoveryKit(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "confirmRecoveryKit") { [state, log, plansChanged] in
            let status = try await state.confirmRecoveryKit(try Self.planID(planID))
            log.info("Recovery details confirmed for plan \(planID)")
            plansChanged()
            return status
        }
    }

    func requestNotificationPermission(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "requestNotificationPermission") { [state, log, notifier] in
            let granted = try await notifier.requestPermission()
            log.info("Notification permission \(granted ? "granted" : "not granted")")
            // Clears or raises `notificationsOff`, and posts any alert that was waiting for permission.
            // Bounded, so a notification centre that doesn't answer can't hold up the reply.
            await state.deliverAlerts(waitingAtMost: .seconds(15))
            return NotificationPermissionReply(granted: granted)
        }
    }

    func prepareForRestart(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        drain(.restart, reply: reply)
    }

    func prepareForReregistration(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        drain(.reregistration, reply: reply)
    }

    /// Replies once no run is in flight. Only a restart drain then exits, through the state's restart
    /// exit (attached in main.swift), which also waits for any other restart reply still owed.
    private func drain(_ purpose: DrainPurpose, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task { [state, log] in
            log.info(purpose.exitsAfterwards
                ? "Asked to restart: finishing the restic step in progress first"
                : "Asked to drain before re-registration: finishing the restic step in progress first")
            let answer: @Sendable (Bool) -> Void = { flushed in
                if !flushed {
                    log.error(AgentState.pingsGivenUp(after: AgentState.drainPingBudget))
                }
                log.info(purpose.exitsAfterwards
                    ? "No run in progress; exiting so launchd starts the agent again"
                    : "No run in progress; staying up, drained, until the app re-registers the agent")
                do {
                    reply(try XPCCoding.encode(DrainReply(drained: true)), nil)
                } catch {
                    reply(nil, "Restorey's agent couldn't encode its reply: \(error.localizedDescription)")
                }
            }
            if purpose == .restart {
                await state.restart(reply: answer)
            } else {
                do {
                    answer(try await state.prepareForReregistration())
                } catch {
                    // A restart drain is under way: the agent exits on its own, so the app must not
                    // unregister it. The app tries again later and finds the new agent.
                    let message = (error as? AgentError)?.message ?? "\(error)"
                    log.info("Refused to drain for re-registration: \(message)")
                    reply(nil, message)
                }
            }
        }
    }

    // MARK: Helpers

    /// - Parameter call: names the call in `agent.log` when it is refused.
    private func respond<T: Encodable & SendableMetatype>(
        _ reply: @escaping @Sendable (Data?, String?) -> Void,
        _ call: String,
        _ work: @escaping @Sendable () async throws -> T
    ) {
        Task { [log] in
            do {
                reply(try XPCCoding.encode(try await work()), nil)
            } catch let error as AgentError {
                // A refusal is an answer, not a fault, but it must leave a trace: a Back Up Now that did
                // nothing is otherwise invisible (final review M5). The message never names a secret.
                log.info("Refused \(call): \(error.message)")
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
}
