import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct RestoreySpikeApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        WindowGroup("Restorey Spike") {
            ProbeWindow(model: model)
                .frame(minWidth: 760, minHeight: 640)
                .task { await model.onLaunch() }
        }
    }
}

@MainActor
@Observable
final class ProbeModel {
    var log: [String] = []
    var lastPing = "—"
    var serviceStatus = "—"
    var backupPaths = "~/Library/Developer"
    var scheduleSeconds = "120"
    let client = AgentClient()

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    var bundlePath: String { Bundle.main.bundlePath }
    /// Spec §8: a quarantined app run from a DMG or Downloads is translocated to a random read-only path.
    var isTranslocated: Bool { bundlePath.contains("/AppTranslocation/") }
    var isInApplications: Bool { bundlePath.hasPrefix("/Applications/") }

    func append(_ title: String, _ text: String) {
        log.insert("[\(Timestamp.now())] \(title)\n\(text)", at: 0)
    }

    func onLaunch() async {
        refreshStatus()
        append("launch", "app \(appVersion) (\(appBuild)) at \(bundlePath)\ntranslocated=\(isTranslocated) inApplications=\(isInApplications)")
        await versionHandshake()
        Task { await heartbeatLoop() }
    }

    func refreshStatus() { serviceStatus = AgentClient.describe(AgentClient.service.status) }

    func register() {
        guard !isTranslocated, isInApplications else {
            append("register", "refused: move the app to /Applications first (translocated=\(isTranslocated))")
            return
        }
        do { try AgentClient.service.register(); append("register", "ok") }
        catch { append("register", "error: \(error)") }
        refreshStatus()
    }

    func unregister() async {
        do { try await AgentClient.service.unregister(); append("unregister", "ok") }
        catch { append("unregister", "error: \(error)") }
        client.reset()
        refreshStatus()
    }

    func send(_ title: String, _ request: [String: Any], timeout: TimeInterval = 600) async {
        append(title, "sent \(JSON.encode(request).replacingOccurrences(of: "\n", with: ""))")
        let reply = await call(request, timeout: timeout)
        append(title, reply)
    }

    /// Encodes on the main actor so only a String crosses into the XPC client.
    func call(_ request: [String: Any], timeout: TimeInterval = 600) async -> String {
        let json = JSON.encode(request)
        return await client.send(json: json, timeout: timeout)
    }

    func heartbeatLoop() async {
        while true {
            let reply = await call(["command": "ping"], timeout: 5)
            let ping = JSON.decode(reply)
            if let pid = ping["pid"] { lastPing = "pid \(pid), build \(ping["build"] ?? "?") at \(Timestamp.now())" }
            else { lastPing = "NO REPLY at \(Timestamp.now()): \(reply)"; client.reset() }
            refreshStatus()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Spec §8 (review 4): on launch, restart the agent if its build differs from the app's.
    func versionHandshake() async {
        let ping = JSON.decode(await call(["command": "ping"], timeout: 5))
        guard let agentBuild = ping["build"] as? String else {
            append("handshake", "agent not reachable: \(ping)"); return
        }
        guard agentBuild != appBuild else {
            append("handshake", "agent build \(agentBuild) matches app"); return
        }
        append("handshake", "agent build \(agentBuild) ≠ app build \(appBuild); asking agent to drain and exit")
        await send("prepareForRestart", ["command": "prepareForRestart"], timeout: 3600)
        client.reset()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            let next = JSON.decode(await call(["command": "ping"], timeout: 5))
            if let build = next["build"] as? String {
                append("handshake", "agent now pid \(next["pid"] ?? "?") build \(build) — \(build == appBuild ? "MATCH" : "STILL DIFFERENT")")
                if build == appBuild { return }
            } else { client.reset() }
        }
        append("handshake", "TIMEOUT: agent did not come back with build \(appBuild) within 60 s")
    }

    var expandedPaths: [String] {
        backupPaths.split(separator: ",").map {
            NSString(string: $0.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        }
    }

    // MARK: Keychain (app side writes, agent side reads)

    func storeKeychainPassword() {
        let status = SpikeKeychain.store(SpikeKeychain.randomSecret(), account: SpikeIDs.keychainAccount)
        append("keychain store", SpikeKeychain.describe(status) + " group=\(SpikeKeychain.accessGroup)")
    }

    func deleteKeychainPassword() {
        append("keychain delete", SpikeKeychain.describe(SpikeKeychain.delete(account: SpikeIDs.keychainAccount)))
    }

    // MARK: Notifications from the app (negative control for Task 5)

    func appRequestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            append("app notif request", "granted=\(granted)")
        } catch { append("app notif request", "error: \(error)") }
    }
}
