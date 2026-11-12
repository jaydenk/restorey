import AgentCore
import Foundation
import OSLog
import RestoreyCore
import Synchronization

/// The agent executable run as restic's `RESTIC_PASSWORD_COMMAND` (`print-password --plan <id>`) or as
/// the S3 `credential_process` (`s3-credentials --plan <id>`), spec §7.
///
/// It holds no secrets and reads no keychain item itself. It asks the running agent over XPC, and the
/// agent answers only when this process's parent is a restic the agent is supervising for that plan
/// (`HelperResponder`). Run by hand, it gets nothing.
///
/// Exit codes: 0 with the payload on stdout; 1 with nothing on stdout for any failure or refusal;
/// 2 when the executable's own path is unknown or can't appear on a `credential_process` line. Every
/// failure goes to os_log (category `helper`), never stderr: minio-go's `cmd.Output()` discards stderr.
/// Nothing logged names the plan or a secret: the agent's refusal reasons name the kind of key, never the
/// keychain account (which embeds the plan ID).
///
/// Helper mode never starts `NSApplication` and never creates the agent's listeners.
enum HelperMode {
    static let commands: [String: HelperRequest.Kind] = [
        "print-password": .repositoryPassword,
        "s3-credentials": .s3Credentials,
    ]
    /// The agent answers at once; this only bounds a wedged connection.
    static let replyTimeout: DispatchTimeInterval = .seconds(30)

    /// Nil when `arguments` isn't a helper command, so the caller starts the agent; otherwise the exit code.
    static func exitCode(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, let kind = commands[arguments[1]] else { return nil }
        let identity = try? Identity.fromBundle(.main)
        let logger = Logger(
            subsystem: identity?.rootID ?? Bundle.main.bundleIdentifier ?? "Restorey", category: "helper")

        // No fallback to argv[0], which the caller chooses: without our own path we can't vouch for it.
        guard let path = Bundle.main.executablePath else {
            logger.error("Refusing to run: the helper can't find its own executable path")
            return 2
        }
        do {
            try CredentialsFile.validateHelperPath(path)
        } catch {
            logger.error("Refusing to run: the helper's path can't be used unquoted (\(String(describing: error), privacy: .public))")
            return 2
        }
        guard arguments.count == 4, arguments[2] == "--plan" else {
            logger.error("Usage: \(arguments[1], privacy: .public) --plan <plan ID>")
            return 1
        }
        guard let identity else {
            logger.error("The helper can't read its identity from Info.plist")
            return 1
        }
        guard let team = AgentListener.teamID(in: .main) else {
            logger.error("RestoreyTeamID is missing or malformed in Info.plist")
            return 1
        }
        let request: Data
        do {
            request = try XPCCoding.encode(HelperRequest(kind: kind, planID: arguments[3]))
        } catch {
            logger.error("The helper couldn't encode its request: \(String(describing: error), privacy: .public)")
            return 1
        }

        switch ask(identity: identity, team: team, request: request) {
        case .success(let payload):
            do {
                try writeToStandardOutput(payload)
                return 0
            } catch {
                logger.error("The helper couldn't write to stdout: \(String(describing: error), privacy: .public)")
                return 1
            }
        case .failure(let failure):
            logger.error("The agent gave the helper nothing: \(failure.reason, privacy: .public)")
            return 1
        }
    }

    struct Failure: Error {
        let reason: String
    }

    /// The first outcome wins: the reply or the connection's error handler, whichever comes first.
    private final class Outcome: Sendable {
        private let value = Mutex<Result<Data, Failure>?>(nil)
        let done = DispatchSemaphore(value: 0)

        func set(_ result: Result<Data, Failure>) {
            let first = value.withLock { current in
                guard current == nil else { return false }
                current = result
                return true
            }
            if first { done.signal() }
        }

        var result: Result<Data, Failure>? { value.withLock { $0 } }
    }

    private static func ask(identity: Identity, team: String, request: Data) -> Result<Data, Failure> {
        let connection = NSXPCConnection(machServiceName: identity.helperServiceName, options: [])
        // Talk only to our own agent, never to whatever else might hold the name.
        connection.setCodeSigningRequirement(
            AgentListener.codeSigningRequirement(bundleID: identity.agentBundleID, team: team))
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
        connection.resume()
        defer { connection.invalidate() }

        let outcome = Outcome()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            outcome.set(.failure(Failure(reason: "XPC error: \(error.localizedDescription)")))
        } as? HelperXPC
        guard let proxy else { return .failure(Failure(reason: "the XPC proxy has the wrong type")) }
        proxy.secret(request) { payload, message in
            if let payload {
                outcome.set(.success(payload))
            } else {
                outcome.set(.failure(Failure(reason: message ?? "the agent replied with neither a payload nor an error")))
            }
        }
        guard outcome.done.wait(timeout: .now() + replyTimeout) == .success, let result = outcome.result else {
            return .failure(Failure(reason: "the agent didn't reply in time"))
        }
        return result
    }

    private static func writeToStandardOutput(_ data: Data) throws {
        var remaining = data[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            remaining = remaining.dropFirst(written)
        }
    }
}
