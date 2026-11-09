import Foundation
import UserNotifications
import os

let agentLog = Logger(subsystem: SpikeIDs.agentLabel, category: "agent")

/// Mutable agent state. An actor, so XPC calls arriving on XPC's queues can't race it.
actor AgentState {
    let startedAt = Timestamp.now()
    private(set) var draining = false
    private(set) var runningPid: Int32?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginRun() -> Bool {
        guard !draining, runningPid == nil else { return false }
        runningPid = 0
        return true
    }
    func setPid(_ pid: Int32) { runningPid = pid }
    func endRun() {
        runningPid = nil
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
    /// Stop accepting runs and wait for the current one to finish.
    func drain() async {
        draining = true
        if runningPid == nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

final class AgentService: NSObject, AgentXPC, NSXPCListenerDelegate, @unchecked Sendable {
    let state = AgentState()

    static let probePaths = ["Library/Safari", "Library/Mail", "Library/Messages"]
        .map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
    static var resultsFile: URL { SpikeIDs.cacheDir.appendingPathComponent("results.jsonl") }
    static var runAtStartFlag: URL { SpikeIDs.cacheDir.appendingPathComponent("run-at-start") }

    // MARK: XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AgentXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func perform(_ requestJSON: String, withReply reply: @escaping @Sendable (String) -> Void) {
        let request = JSON.decode(requestJSON)
        Task.detached { [self] in
            let result = await handle(request)
            reply(JSON.encode(result))
        }
    }

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        let command = request["command"] as? String ?? ""
        let source = ResticRunner.PasswordSource(rawValue: request["passwordSource"] as? String ?? "env") ?? .env
        switch command {
        case "ping":
            return ping()
        case "initRepo":
            return await runRestic(["init", "--json"], source: source, label: "initRepo")
        case "backup":
            let paths = (request["paths"] as? [String]) ?? Self.probePaths
            // Absolute paths only, and "--" before them, so a path can never be read as a flag.
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                return ["error": "paths must be absolute"]
            }
            return await backup(paths: paths, source: source, label: "backup")
        case "probeFDA":
            return await probeFDA()
        case "schedule":
            let delay = request["afterSeconds"] as? Double ?? 120
            scheduleBackup(after: delay, source: source)
            return ["scheduled": true, "afterSeconds": delay, "passwordSource": source.rawValue]
        case "runAtStart":
            return setRunAtStart(request["enabled"] as? Bool ?? false)
        case "results":
            let text = (try? String(contentsOf: Self.resultsFile, encoding: .utf8)) ?? ""
            return ["results": Array(text.split(separator: "\n").suffix(10).map(String.init))]
        case "keychainRead":
            let (value, status) = SpikeKeychain.read(account: SpikeIDs.keychainAccount)
            return ["found": value != nil, "status": SpikeKeychain.describe(status), "accessGroup": SpikeKeychain.accessGroup]
        case "notifRequest":
            return await notificationRequest()
        case "notifPost":
            return await notificationPost()
        case "notifSettings":
            return await notificationSettings()
        case "prepareForRestart":
            await state.drain()
            agentLog.notice("prepareForRestart: drained, exiting so launchd relaunches the agent")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return ["exiting": true, "pid": getpid()]
        default:
            return ["error": "unknown command '\(command)'"]
        }
    }

    // MARK: Commands

    func ping() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "build": info["CFBundleVersion"] as? String ?? "?",
            "pid": getpid(),
            "startedAt": startedAtSync,
            "executable": Bundle.main.executableURL?.path ?? "?",
            "resticPath": ResticRunner.resticURL.path,
            "resticExists": FileManager.default.isExecutableFile(atPath: ResticRunner.resticURL.path),
        ]
    }
    private let startedAtSync = Timestamp.now()

    func runRestic(_ arguments: [String], source: ResticRunner.PasswordSource, label: String) async -> [String: Any] {
        guard await state.beginRun() else { return ["error": "busy or draining"] }
        defer { Task { await state.endRun() } }
        do {
            let runner = ResticRunner(source: source)
            let result = try runner.run(arguments) { pid in Task { await self.state.setPid(pid) } }
            var dict = result.dictionary
            dict["command"] = label
            dict["passwordSource"] = source.rawValue
            record(dict)
            return dict
        } catch {
            let dict: [String: Any] = ["command": label, "error": "\(error)"]
            record(dict)
            return dict
        }
    }

    func backup(paths: [String], source: ResticRunner.PasswordSource, label: String) async -> [String: Any] {
        await runRestic(["backup", "--json", "--host", "restorey-spike", "--tag", "restorey-spike", "--"] + paths,
                        source: source, label: label)
    }

    func probeFDA() async -> [String: Any] {
        var inAgent: [String: String] = [:]
        let fm = FileManager.default
        for path in Self.probePaths {
            guard fm.fileExists(atPath: path) else { inAgent[path] = "absent"; continue }
            do {
                let items = try fm.contentsOfDirectory(atPath: path)
                inAgent[path] = "ok (\(items.count) items)"
            } catch {
                inAgent[path] = "denied: \((error as NSError).domain) \((error as NSError).code)"
            }
        }
        let existing = Self.probePaths.filter { fm.fileExists(atPath: $0) }
        // --dry-run still reads and chunks every file (so TCC is exercised) but writes nothing:
        // a real backup of these folders put ~10 GB of the owner's mail into the test repo.
        let restic = await runRestic(["backup", "--json", "--dry-run", "--host", "restorey-spike", "--"] + existing,
                                     source: .env, label: "probeFDA-restic")
        return ["inAgent": inAgent, "restic": restic, "agentPid": getpid()]
    }

    func scheduleBackup(after seconds: Double, source: ResticRunner.PasswordSource) {
        agentLog.notice("scheduled backup in \(seconds)s, source \(source.rawValue)")
        Task.detached { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            let keychain = SpikeKeychain.read(account: SpikeIDs.keychainAccount)
            var dict = await backup(paths: Self.probePaths.filter { FileManager.default.fileExists(atPath: $0) },
                                    source: source, label: "scheduled")
            dict["keychainPreRead"] = SpikeKeychain.describe(keychain.1)
            record(dict)
        }
    }

    func setRunAtStart(_ enabled: Bool) -> [String: Any] {
        try? FileManager.default.createDirectory(at: SpikeIDs.cacheDir, withIntermediateDirectories: true)
        if enabled {
            FileManager.default.createFile(atPath: Self.runAtStartFlag.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: Self.runAtStartFlag)
        }
        return ["runAtStart": enabled]
    }

    func startupHook() {
        if FileManager.default.fileExists(atPath: Self.runAtStartFlag.path) {
            scheduleBackup(after: 60, source: .keychain)
        }
    }

    func record(_ dict: [String: Any]) {
        var line = dict
        line["at"] = Timestamp.now()
        line["agentPid"] = getpid()
        line["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        guard let data = (JSON.encode(line).replacingOccurrences(of: "\n", with: "") + "\n").data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: SpikeIDs.cacheDir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.resultsFile) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: Self.resultsFile)
        }
    }

    // MARK: Notifications

    func notificationRequest() async -> [String: Any] {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return ["granted": granted]
        } catch {
            return ["error": "\(error)"]
        }
    }

    func notificationPost() async -> [String: Any] {
        let content = UNMutableNotificationContent()
        content.title = "Restorey Spike"
        content.body = "Test notification from the background agent (pid \(getpid()))."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return ["posted": true]
        } catch {
            return ["posted": false, "error": "\(error)"]
        }
    }

    func notificationSettings() async -> [String: Any] {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return ["authorizationStatus": settings.authorizationStatus.rawValue,
                "alertSetting": settings.alertSetting.rawValue,
                "legend": "authorizationStatus 0 notDetermined, 1 denied, 2 authorized, 3 provisional"]
    }
}
