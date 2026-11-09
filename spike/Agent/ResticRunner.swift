import Foundation

/// Runs the bundled restic as a child of the agent. Uses Foundation.Process (posix_spawn
/// underneath) and never disclaims responsibility, so TCC should attribute it to the app.
struct ResticRunner: Sendable {
    enum PasswordSource: String, Sendable {
        case env       // repo-env: random password in a 0600 file, passed in the child's env only
        case keychain  // repo-kc: RESTIC_PASSWORD_COMMAND = this agent's own executable
    }

    static var resticURL: URL {
        // Agent lives at Restorey Spike.app/Contents/Helpers/RestoreySpikeAgent.app
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("restic")
    }

    static func repoURL(_ source: PasswordSource) -> URL {
        SpikeIDs.cacheDir.appendingPathComponent(source == .env ? "repo-env" : "repo-kc", isDirectory: true)
    }

    static var envPasswordFile: URL { SpikeIDs.cacheDir.appendingPathComponent("repo-env.password") }

    let source: PasswordSource
    var repo: String? = nil
    var extraEnv: [String: String] = [:]

    func environment() throws -> [String: String] {
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "RESTIC_PROGRESS_FPS": "0.5",
        ]
        switch source {
        case .env:
            env["RESTIC_PASSWORD"] = try Self.envPassword()
        case .keychain:
            let me = Bundle.main.executableURL!.resolvingSymlinksInPath().path
            env["RESTIC_PASSWORD_COMMAND"] = "'\(me)' print-password --account \(SpikeIDs.keychainAccount)"
        }
        env.merge(extraEnv) { _, new in new }
        return env
    }

    static func envPassword() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: SpikeIDs.cacheDir, withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: envPasswordFile, encoding: .utf8) { return existing }
        let secret = SpikeKeychain.randomSecret()
        fm.createFile(atPath: envPasswordFile.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600])
        return secret
    }

    struct Result: Sendable {
        var exitCode: Int32
        var durationSeconds: Double
        var permissionErrors: Int
        var errorSamples: [String]
        var stderrTail: [String]
        var summary: String?
        var pid: Int32

        var dictionary: [String: Any] {
            [
                "exitCode": exitCode, "durationSeconds": durationSeconds,
                "permissionErrors": permissionErrors, "errorSamples": errorSamples,
                "stderrTail": stderrTail, "summary": summary ?? NSNull(), "pid": pid,
            ]
        }
    }

    /// Runs `restic <arguments>` with --repo and --cache-dir. `onStart` receives the child pid.
    func run(_ arguments: [String], onStart: @Sendable (Int32) -> Void = { _ in }) throws -> Result {
        let repoPath = repo ?? Self.repoURL(source).path
        let process = Process()
        process.executableURL = Self.resticURL
        process.arguments = ["--repo", repoPath,
                             "--cache-dir", SpikeIDs.cacheDir.appendingPathComponent("restic").path] + arguments
        process.environment = try environment()
        // Spec §8: backups should be noticeable but not disruptive.
        process.qualityOfService = .utility
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let started = Date()
        try process.run()
        onStart(process.processIdentifier)
        // Read both pipes concurrently so neither fills and blocks restic.
        let errData = LockedData()
        let errThread = Thread { errData.set(err.fileHandleForReading.readDataToEndOfFile()) }
        errThread.start()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while errData.get() == nil { Thread.sleep(forTimeInterval: 0.01) }

        var permissionErrors = 0
        var samples: [String] = []
        var summary: String?
        let lines = (String(data: outData, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
            + (String(data: errData.get() ?? Data(), encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        for line in lines {
            let msg = JSON.decode(line)
            switch msg["message_type"] as? String {
            case "error":
                let text = ((msg["error"] as? [String: Any])?["message"] as? String) ?? line
                if text.localizedCaseInsensitiveContains("operation not permitted") { permissionErrors += 1 }
                if samples.count < 5 { samples.append("\(msg["item"] as? String ?? "?"): \(text)") }
            case "summary":
                summary = line
            default:
                if msg.isEmpty, line.localizedCaseInsensitiveContains("operation not permitted") { permissionErrors += 1 }
            }
        }
        let stderrLines = (String(data: errData.get() ?? Data(), encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        return Result(exitCode: process.terminationStatus,
                      durationSeconds: Date().timeIntervalSince(started),
                      permissionErrors: permissionErrors, errorSamples: samples,
                      stderrTail: Array(stderrLines.suffix(20)), summary: summary,
                      pid: process.processIdentifier)
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func set(_ data: Data) { lock.withLock { value = data } }
    func get() -> Data? { lock.withLock { value } }
}
