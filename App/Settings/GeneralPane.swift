import AppKit
import RestoreyCore
import SwiftUI

/// Settings → General (UI design §6.1, mockup `v0.1-settings.html`): open at login, Full Disk Access and
/// notifications with their fixes, the background agent and its version, the logs folder, and the note shown while
/// the menu bar icon is hidden. The words are `SettingsGeneral`'s.
///
/// What the user can change elsewhere (Login Items, Full Disk Access, notifications in System Settings) is read
/// again whenever Restorey comes back to the front.
struct GeneralPane: View {
    let context: SettingsContext
    @Bindable var state: ShellState
    @State private var loginStatus: AgentServiceStatus?
    @State private var loginError: String?
    @State private var asking = false

    private var supervisor: AgentSupervisor { context.supervisor }

    var body: some View {
        Form {
            if state.statusItemHidden {
                Label(statusItemHiddenNote, systemImage: "menubar.rectangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                openAtLogin
                LabeledContent("Full Disk Access") {
                    LineView(line: SettingsGeneral.fullDiskAccess(missing: supervisor.lastKnownStatus?.fdaMissing),
                             perform: perform)
                }
                LabeledContent("Notifications") {
                    LineView(line: SettingsGeneral.notifications(hello: supervisor.lastHello),
                             busy: asking, perform: perform)
                }
                LabeledContent("Background agent") {
                    LineView(line: SettingsGeneral.agent(health: supervisor.health, hello: supervisor.lastHello),
                             perform: perform)
                }
                LabeledContent("Logs") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([supervisor.identity.logsDirectory()])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder private var openAtLogin: some View {
        let login = SettingsGeneral.openAtLogin(loginStatus ?? context.loginItem.status)
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { login.isOn }, set: setOpenAtLogin))
                // In a grouped form the switch's own label is drawn apart from it, and VoiceOver read the switch as
                // "0" (live finding 4).
                .accessibilityLabel("Open at login")
            if let note = login.note {
                HStack(alignment: .firstTextBaseline) {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(GeneralAction.openLoginItems.buttonTitle) { context.loginItem.openLoginItems() }
                        .controlSize(.small)
                }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Registers or unregisters, then reads the status again: switching on while the user has Restorey switched
    /// off in Login Items leaves it `requiresApproval`, and the switch must show that, not what was asked.
    private func setOpenAtLogin(_ on: Bool) {
        do {
            try context.loginItem.setEnabled(on)
            loginError = nil
        } catch {
            loginError = "Restorey couldn't change Open at login: \(error.localizedDescription)"
        }
        loginStatus = context.loginItem.status
    }

    private func refresh() async {
        loginStatus = context.loginItem.status
        // Each reply reaches the supervisor, which the lines read.
        _ = await supervisor.connection.probeFullDiskAccess()
        await supervisor.refreshHello()
    }

    private func perform(_ action: GeneralAction) {
        switch action {
        case .openFullDiskAccess:
            NSWorkspace.shared.open(StatusItemController.fullDiskAccessURL)
        case .askForNotifications:
            guard !asking else { return }
            asking = true
            Task {
                _ = await supervisor.connection.requestNotificationPermission()
                await supervisor.refreshHello()
                asking = false
            }
        case .openNotificationSettings:
            // The agent posts the notifications, so it is the app to turn them on for.
            if let url = StatusItemController.notificationsURL(bundleID: supervisor.identity.agentBundleID) {
                NSWorkspace.shared.open(url)
            }
        case .restartAgent:
            supervisor.restartAgent()
        case .openLoginItems:
            supervisor.openLoginItems()
        }
    }
}

/// A General line: its words, coloured by severity, and its fix's button.
private struct LineView: View {
    let line: SettingsGeneral.Line
    var busy = false
    let perform: (GeneralAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(line.value)
                .foregroundStyle(line.severity == .error ? .red : line.severity == .warning ? .orange : .primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            if busy { ProgressView().controlSize(.small) }
            if let action = line.action {
                Button(action.buttonTitle) { perform(action) }
                    .disabled(busy)
            }
        }
    }
}
