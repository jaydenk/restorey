import AppKit
import Observation
import RestoreyCore
import SwiftUI

/// Settings → Notifications (visual polish §4): which notifications Restorey posts, Mac-wide, and whether macOS lets
/// its background process post them. A switch saves at once, the whole set going to the agent; the permission line's
/// words are `SettingsGeneral`'s. The switches follow the agent's status, so a refusal puts them back. Permission is
/// read again whenever Restorey comes back to the front, since the user may have changed it in System Settings.
struct NotificationsPane: View {
    let supervisor: AgentSupervisor
    @State private var model: NotificationsEditModel
    /// The permission question is up.
    @State private var asking = false

    init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
        _model = State(initialValue: NotificationsEditModel(supervisor: supervisor))
    }

    private var connected: Bool { supervisor.lastKnownStatus?.notifications != nil && supervisor.health == .healthy }

    var body: some View {
        Form {
            Section("Notifications") {
                if !connected {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Restorey’s background process…").foregroundStyle(.secondary)
                    }
                }
                // In a grouped form the switch's own label is drawn apart from it, and VoiceOver reads the switch as
                // "0" (live finding 4), so each is named.
                Toggle("Backup started", isOn: binding(\.backupStarted))
                    .accessibilityLabel("Backup started")
                Toggle("Backup finished", isOn: binding(\.backupFinished))
                    .accessibilityLabel("Backup finished")
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Problems with backups", isOn: binding(\.problems))
                        .accessibilityLabel("Problems with backups")
                    if !model.shown.problems {
                        Text("When this is off, the menu bar icon still shows a problem, and so does a check-in URL if you’ve set one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = model.error {
                    SeverityText(error, severity: .warning, font: .callout)
                }
            }
            .disabled(!connected)
            Section {
                LabeledContent("Permission") {
                    LineView(line: SettingsGeneral.notifications(hello: supervisor.lastHello), busy: asking) { action in
                        guard !asking else { return }
                        asking = true
                        Task {
                            await GeneralActionRunner.run(action, supervisor: supervisor)
                            asking = false
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await supervisor.refreshHello() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await supervisor.refreshHello() }
        }
    }

    private func binding(_ key: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.shown[keyPath: key] },
            set: { on in Task { await model.set(key, to: on) } }
        )
    }
}

/// The switches as shown: what the agent has, with a change made while a save is in flight kept on screen until the
/// agent answers. Saves are serialised like `NetworkEditModel.commit()`: one asked for while another is in flight is
/// sent when that returns, from the latest wanted value, so the agent ends with the last.
@MainActor
@Observable
final class NotificationsEditModel {
    /// What the switches have been set to and not yet saved; nil when they show what the agent has.
    private var wanted: NotificationSettings?
    private(set) var error: String?
    private var saving = false
    @ObservationIgnored private let supervisor: AgentSupervisor

    init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
    }

    /// The agent's settings, or the wanted ones while a save is in flight.
    var shown: NotificationSettings {
        wanted ?? supervisor.lastKnownStatus?.notifications ?? .defaults
    }

    func set(_ key: WritableKeyPath<NotificationSettings, Bool>, to on: Bool) async {
        var settings = shown
        guard settings[keyPath: key] != on else { return }
        settings[keyPath: key] = on
        error = nil
        wanted = settings
        if SettingsGeneral.asksPermission(turningOn: on, authorised: supervisor.lastHello?.notificationsAuthorised) {
            // The agent asks macOS; the question and the save don't wait on each other.
            Task {
                _ = await supervisor.connection.requestNotificationPermission()
                await supervisor.refreshHello()
            }
        }
        guard !saving else { return }
        saving = true
        defer { saving = false }
        while let request = wanted {
            switch await supervisor.connection.saveNotificationSettings(request) {
            case .success:
                // A change made meanwhile replaced `wanted`; it is sent next.
                if wanted == request {
                    wanted = nil
                }
            case .failure(let failure):
                // Back to what the agent has, with its sentence; nothing queues.
                wanted = nil
                error = FormValidation.sentence(failure.description)
            }
        }
    }
}
