import ServiceManagement
import SwiftUI

struct ProbeWindow: View {
    @Bindable var model: ProbeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restorey Spike \(model.appVersion) (\(model.appBuild)) — throwaway").font(.headline)
            Text("Agent service: \(model.serviceStatus) · heartbeat: \(model.lastPing)").font(.callout).textSelection(.enabled)

            group("Agent") {
                Button("Register") { model.register() }
                Button("Unregister") { Task { await model.unregister() } }
                Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                Button("Ping") { Task { await model.send("ping", ["command": "ping"], timeout: 5) } }
                Button("Version handshake") { Task { await model.versionHandshake() } }
                Button("Prepare for restart") { Task { await model.send("prepareForRestart", ["command": "prepareForRestart"], timeout: 3600) } }
            }
            group("Restic (env password)") {
                Button("Init repo") { Task { await model.send("initRepo env", ["command": "initRepo", "passwordSource": "env"]) } }
                Button("Probe FDA") { Task { await model.send("probeFDA", ["command": "probeFDA"]) } }
                TextField("paths, comma separated", text: $model.backupPaths).frame(width: 260)
                Button("Back up paths") { Task { await model.send("backup env", ["command": "backup", "passwordSource": "env", "paths": model.expandedPaths]) } }
            }
            group("Keychain") {
                Button("Store new password") { model.storeKeychainPassword() }
                Button("Delete") { model.deleteKeychainPassword() }
                Button("Agent reads") { Task { await model.send("keychainRead", ["command": "keychainRead"]) } }
                Button("Init repo") { Task { await model.send("initRepo kc", ["command": "initRepo", "passwordSource": "keychain"]) } }
                Button("Back up probe paths") { Task { await model.send("backup kc", ["command": "backup", "passwordSource": "keychain"]) } }
            }
            group("Scheduled (keychain)") {
                TextField("seconds", text: $model.scheduleSeconds).frame(width: 60)
                Button("Schedule") { Task { await model.send("schedule", ["command": "schedule", "passwordSource": "keychain", "afterSeconds": Double(model.scheduleSeconds) ?? 120]) } }
                Button("Run 60 s after agent start: on") { Task { await model.send("runAtStart", ["command": "runAtStart", "enabled": true]) } }
                Button("off") { Task { await model.send("runAtStart", ["command": "runAtStart", "enabled": false]) } }
                Button("Results") { Task { await model.send("results", ["command": "results"]) } }
            }
            group("Notifications") {
                Button("App requests") { Task { await model.appRequestNotifications() } }
                Button("Agent requests") { Task { await model.send("notifRequest", ["command": "notifRequest"]) } }
                Button("Agent settings") { Task { await model.send("notifSettings", ["command": "notifSettings"]) } }
                Button("Agent posts") { Task { await model.send("notifPost", ["command": "notifPost"]) } }
            }

            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.joined(separator: "\n\n"), forType: .string)
                }
                Button("Clear") { model.log.removeAll() }
            }
            ScrollView {
                Text(model.log.joined(separator: "\n\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary)
        }
        .padding()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
