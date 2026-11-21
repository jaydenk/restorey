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
    private let location: LocationPermission
    /// `ExecutableFingerprint` of the binary at launch, reported in `hello`.
    private let executableFingerprint: String?
    /// Called after a change that can make a plan due now: a save, a recovery kit confirmation, a resume.
    private let plansChanged: @Sendable () -> Void

    init(
        state: AgentState, log: AppLog, notifier: Notifier, location: LocationPermission,
        executableFingerprint: String?, plansChanged: @escaping @Sendable () -> Void
    ) {
        self.executableFingerprint = executableFingerprint
        self.state = state
        self.log = log
        self.notifier = notifier
        self.location = location
        self.plansChanged = plansChanged
    }

    // MARK: AgentXPC

    func hello(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Not logged: the app's heartbeat sends one every 10 s. Built in process from what the agent holds,
        // never by asking the notification centre (Ruling R68): a hung usernoted must not make the app
        // think the agent is dead and unregister it mid-backup.
        respond(reply, "hello") { [state, location, executableFingerprint] in
            _ = try Self.decode(HelloRequest.self, from: request)
            let info = Bundle.main.infoDictionary ?? [:]
            var hello = await state.helloReply(
                agentVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                agentBuild: info["CFBundleVersion"] as? String ?? "unknown",
                executablePath: Bundle.main.executableURL?.path ?? "unknown",
                executableFingerprint: executableFingerprint)
            // The last authorisation Core Location reported, held in process: never a call to it (R68).
            hello.locationAuthorised = location.knownAuthorised
            // Held in process too: read again on each change Core Location reports and on each `locationAccess`.
            hello.locationServicesEnabled = location.knownServicesEnabled
            return hello
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

    func saveNetworkSettings(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "saveNetworkSettings") { [state, log, plansChanged] in
            let settings = try Self.decode(NetworkSettings.self, from: request)
            let status = try await state.saveNetworkSettings(settings)
            // Counts only: Wi-Fi names say where the user goes, which a log doesn't need.
            log.info(
                "Saved the network settings: upload limit \(Self.describe(settings.uploadLimit))"
                    + "\(settings.limitWindow == nil ? "" : " inside a window"), "
                    + "skip on a constrained network \(settings.skipOnConstrainedNetwork ? "on" : "off"), "
                    + "\(settings.skippedWiFiNames.count) Wi-Fi names to skip")
            // A rule turned off can make a skipped plan due now.
            plansChanged()
            return status
        }
    }

    func runUploadSpeedTest(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // The test logs itself (`SpeedTester`), so only a refusal is logged here. Not by `respond`: its message names a
        // skipped Wi-Fi network, which a Release log never does.
        respond(reply, "runUploadSpeedTest", logsRefusal: false) { [state, log] in
            do {
                return try await state.runUploadSpeedTest()
            } catch let error as AgentError {
                if case .speedTestRefused(.skippedWiFi) = error {
                    log.info("Refused runUploadSpeedTest: the Wi-Fi network is one backups skip")
                } else {
                    log.info("Refused runUploadSpeedTest: \(error.message)")
                }
                throw error
            }
        }
    }

    /// The Mac-wide upload limit as the log names it: "none", "2048 KiB/s", "50% of the measured upload speed".
    private static func describe(_ limit: MacUploadLimit) -> String {
        switch limit {
        case .none: "none"
        case .rate(let kiB, _): "\(kiB) KiB/s"
        case .percent(let percent): "\(percent)% of the measured upload speed"
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
        // `AgentState.backUpNow` logs its own refusals (final review M5), where they are tested; only a
        // malformed plan ID, refused before the state sees the call, is logged here.
        respond(reply, "Back Up Now", logsRefusal: false) { [state, log] in
            let id: UUID?
            do {
                id = try planID.map(Self.planID)
            } catch let error as AgentError {
                log.info("Refused Back Up Now: \(error.message)")
                throw error
            }
            let reply = try await state.backUpNow(id)
            log.info("Back up now: \(planID.map { "plan \($0)" } ?? "every plan")\(reply.alreadyRunning ? " (already backing up)" : "")")
            return reply
        }
    }

    func pause(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "pause") { [state, log] in
            let request = try PauseRequest.decoded(from: request)
            let status = try await state.pause(request.planID, for: request.length)
            log.info("Paused plan \(request.planID.uuidString) (\(request.length.rawValue))")
            return status
        }
    }

    func cancel(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "cancel") { [state, log] in
            let reply = try await state.cancel(try Self.planID(planID))
            // Only a Cancel that stopped something is worth a line: one with no run in progress changes nothing.
            if reply.stoppedARun { log.info("Cancelled the run of plan \(planID)") }
            return reply.result
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

    func probeRepositoryCredentials(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "probeRepositoryCredentials") { [state, log] in
            let decoded = try Self.decode(CredentialProbeRequest.self, from: request)
            let probe = try await state.probeRepository(decoded.planID, candidates: decoded.secrets)
            let found = switch probe.state {
            case .empty: "nothing at the address"
            case .existing: "the repository opens with them"
            case .passwordRejected: "the repository doesn't open with them"
            }
            log.info("Checked new credentials for plan \(decoded.planID.uuidString): \(found)")
            return probe
        }
    }

    func probeRepository(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "probeRepository") { [state, log] in
            let probe = try await state.probeRepository(try Self.planID(planID))
            switch probe.state {
            case .empty: log.info("Probed the repository address for plan \(planID): nothing there")
            case .existing(let report):
                log.info("Probed the repository address for plan \(planID): a repository with \(report.snapshotCount) snapshots")
            case .passwordRejected:
                log.info("Probed the repository address for plan \(planID): a repository its password doesn't open")
            }
            return probe
        }
    }

    func previewEarlierSnapshots(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "previewEarlierSnapshots") { [state, log] in
            let preview = try await state.previewEarlierSnapshots(try Self.planID(planID))
            // Counts only: the IDs are in the reply, and a dry run removed nothing.
            let counts = preview.groups.map { "\($0.removeIDs.count) of \($0.total)" }.joined(separator: ", ")
            log.info("Counted earlier snapshots for plan \(planID): \(preview.groups.count) groups, retention would remove [\(counts)]")
            return preview
        }
    }

    func removeEarlierSnapshots(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "removeEarlierSnapshots") { [state, log] in
            let decoded = try Self.decode(EarlierSnapshotsRequest.self, from: request)
            let removal = try await state.removeEarlierSnapshots(decoded)
            log.info(
                "Removed \(removal.removed) earlier snapshots for plan \(decoded.planID.uuidString) (\(removal.leftAlone) confirmed ones left)")
            return removal
        }
    }

    func removeEarlierSnapshotsAfterNextBackup(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "removeEarlierSnapshotsAfterNextBackup") { [state, log] in
            let decoded = try Self.decode(EarlierSnapshotsRequest.self, from: request)
            let status = try await state.removeEarlierSnapshotsAfterNextBackup(decoded)
            log.info(
                "Plan \(decoded.planID.uuidString) removes \(decoded.confirmation.snapshotIDs.count) confirmed earlier snapshots after its next backup")
            return status
        }
    }

    func history(_ planID: String?, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Not logged: the app reads it whenever a history view is shown.
        respond(reply, "history") { [state] in try await state.history(try planID.map(Self.planID)) }
    }

    func recoveryKit(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "recoveryKit") { [state, log] in
            let kit = try await state.recoveryKit(try Self.planID(planID))
            // The plan and a count only: the reply itself is never logged.
            log.info("Sent the recovery kit for plan \(planID) to the app (\(kit.secrets.count) secrets)")
            return kit
        }
    }

    func probeFullDiskAccess(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Not logged: setup polls it every 2 s. A change shows in the status.
        respond(reply, "probeFullDiskAccess") { [state] in try await state.probeFullDiskAccess() }
    }

    func dismissOffMacNote(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "dismissOffMacNote") { [state, log] in
            let status = try await state.dismissOffMacNote(try Self.planID(planID))
            log.info("Dismissed the off-Mac monitoring note for plan \(planID)")
            return status
        }
    }

    /// `request` is a `ConfirmRecoveryKitRequest`, or the bare plan ID an app from before it sends.
    func confirmRecoveryKit(_ request: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "confirmRecoveryKit") { [state, log, plansChanged] in
            let confirm: ConfirmRecoveryKitRequest
            do {
                confirm = try ConfirmRecoveryKitRequest(message: request)
            } catch {
                throw AgentError.invalidRequest("ConfirmRecoveryKitRequest is malformed")
            }
            let status = try await state.confirmRecoveryKit(
                planID: confirm.planID, kitDigest: confirm.kitDigest, startFirstBackup: confirm.startFirstBackup)
            let id = confirm.planID.uuidString
            log.info("Recovery details confirmed for plan \(id)\(confirm.startFirstBackup ? " at setup’s Start" : "")")
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

    func requestLocationPermission(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        respond(reply, "requestLocationPermission") { [log, location] in
            let answer = await location.request()
            let name = WiFiName.current()
            #if DEBUG
            let readable = name.map { "readable: \"\($0)\"" } ?? "not readable"
            #else
            // A Release log never names the network, which says where the user is.
            let readable = name == nil ? "not readable" : "readable"
            #endif
            let services = answer.servicesEnabled == false ? " (Location Services is off for this Mac)" : ""
            log.info("Location permission \(answer.status)\(services); the Wi-Fi name is \(readable)")
            return answer
        }
    }

    func locationAccess(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Not logged: the Network pane asks each time it appears or Restorey comes to the front.
        respond(reply, "locationAccess") { [location] in await location.current() }
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

    /// - Parameters:
    ///   - call: names the call in `agent.log` when it is refused.
    ///   - logsRefusal: false when the state already logs the call's refusals.
    private func respond<T: Encodable & SendableMetatype>(
        _ reply: @escaping @Sendable (Data?, String?) -> Void,
        _ call: String,
        logsRefusal: Bool = true,
        _ work: @escaping @Sendable () async throws -> T
    ) {
        Task { [log] in
            do {
                reply(try XPCCoding.encode(try await work()), nil)
            } catch let error as AgentError {
                // A refusal is an answer, not a fault, but it must leave a trace (final review M5). The
                // message never names a secret.
                if logsRefusal { log.info("Refused \(call): \(error.message)") }
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
