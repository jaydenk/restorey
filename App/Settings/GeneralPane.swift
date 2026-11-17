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
            // While it is missing, Full Disk Access is a section of its own with the tile, the why and the button
            // across the form's width (Task 17c, P6), and first, since backups miss folders until it is fixed; once on
            // (or while checking), it is one row with the others.
            if fullDiskAccess == .missing {
                Section("Full Disk Access") {
                    fullDiskAccessBlock
                }
            }
            Section {
                openAtLogin
                if fullDiskAccess != .missing {
                    LabeledContent("Full Disk Access") { fullDiskAccessBlock }
                }
                LabeledContent("Notifications") {
                    LineView(line: SettingsGeneral.notifications(hello: supervisor.lastHello),
                             busy: asking, perform: perform)
                }
                LabeledContent("Backups in the background") {
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

    private var fullDiskAccess: FullDiskAccessGuide.State {
        FullDiskAccessGuide.State(missing: supervisor.lastKnownStatus?.fdaMissing)
    }

    private var fullDiskAccessBlock: some View {
        FullDiskAccessBlock(state: fullDiskAccess, openSettings: { perform(.openFullDiskAccess) })
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
                    Text(note).explanatoryNote()
                    Button(GeneralAction.openLoginItems.buttonTitle) { context.loginItem.openLoginItems() }
                        .controlSize(.small)
                }
            }
            if let loginError {
                SeverityText(loginError)
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
            loginError = "Restorey couldn’t change Open at login: \(error.localizedDescription)"
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

/// A General line: its severity’s symbol, its words and its fix’s button.
private struct LineView: View {
    let line: SettingsGeneral.Line
    var busy = false
    let perform: (GeneralAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let severity = line.severity { SeverityIcon(severity: severity) }
            Text(line.value)
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
