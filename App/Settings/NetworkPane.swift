import AppKit
import RestoreyCore
import SwiftUI

/// Settings → Network (UI design §6.3, product spec §5.5, Rulings P2-6 to P2-8 and R69): the Mac-wide upload limit,
/// the hotspot and Low Data Mode rule, and the Wi-Fi networks to skip. Changes apply as they are made: a toggle or
/// picker at once, a text field when editing ends. A value the agent refuses stays in its field, with the agent's
/// sentence beside the form. Every decision is `NetworkEdit`'s and `WiFiNameAccess`'s; `NetworkEditModel` does the calls.
///
/// Location permission is asked for only when the user first adds a network, and what the list says without it is
/// asked of the agent (`locationAccess`, never a prompt) when the pane appears and whenever Restorey comes back to the
/// front, since the user may have changed it in System Settings.
struct NetworkPane: View {
    let supervisor: AgentSupervisor
    let slot: NetworkEditorSlot

    /// System Settings → Privacy & Security → Location Services.
    static let locationServicesURL =
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices")!

    private var status: AgentStatus? { supervisor.lastKnownStatus }

    var body: some View {
        Group {
            if let model = slot.model {
                NetworkForm(model: model, connected: supervisor.health == .healthy)
            } else if let configError = status?.configError {
                unavailable("Restorey can’t read its settings: \(FormValidation.sentence(configError))")
            } else if status != nil {
                // An agent from before the Mac-wide rules (schema 3) sends none.
                unavailable("Restorey didn’t get the network settings. Use Restart Backups in General.")
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Restorey’s background process…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: status?.network, initial: true) { _, network in
            guard let network else { return }
            if let model = slot.model {
                model.rebase(on: network)
            } else {
                slot.model = NetworkEditModel(settings: network, supervisor: supervisor, location: slot.location)
            }
        }
        // The slot's Location state, not the model's: it exists before the first status makes the model.
        .task { await slot.location.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await slot.location.refresh() }
        }
    }

    private func unavailable(_ sentence: String) -> some View {
        SeverityText(sentence, severity: .warning, font: .body)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NetworkForm: View {
    @Bindable var model: NetworkEditModel
    /// Restorey’s background process is answering. While it isn't, the form is off and nothing queues: a change
    /// would only fail, leaving a control showing a value the background process doesn't have.
    let connected: Bool

    private enum TimeField { case start, end }
    @FocusState private var timeFocus: TimeField?

    var body: some View {
        VStack(spacing: 0) {
            if !connected {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Restorey’s background process…").foregroundStyle(.secondary)
                }
                .padding(12)
                Divider()
            }
            Form {
                Section {
                    limit
                    speed
                    if model.fields.limitKind != .none { window }
                    now
                    Toggle("Skip on a hotspot or in Low Data Mode", isOn: $model.fields.skipOnConstrainedNetwork)
                        // In a grouped form the switch's own label is drawn apart from it (live finding 4).
                        .accessibilityLabel("Skip on a hotspot or in Low Data Mode")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Backups uploading together share the limit, and a plan’s own limit applies too: the smaller "
                            + "one wins. A percentage is of this network’s upload speed, which Restorey measures once a day.")
                            .explanatoryNote()
                        Text("These rules apply only to plans that back up to another machine, such as S3, B2 or a restic "
                            + "server. Backups to a folder or drive on this Mac are never skipped or limited.")
                            .explanatoryNote()
                    }
                }
                Section("Skip on these Wi-Fi networks") {
                    wiFiList
                    addRow
                    accessNote
                }
            }
            .formStyle(.grouped)
            .disabled(!connected)
            if let message = refusal {
                Divider()
                HStack(spacing: 8) {
                    SeverityText(message)
                    Spacer()
                    if model.saving { ProgressView().controlSize(.small) }
                }
                .font(.callout)
                .padding(12)
            }
        }
        // A toggle or picker applies at once; a text field when editing ends (`commitSoon`).
        .onChange(of: model.fields.skipOnConstrainedNetwork) { commitSoon() }
        .onChange(of: model.fields.windowEnabled) { commitSoon() }
        .onChange(of: model.fields.windowDays) { commitSoon() }
        // A window time applies when editing ends (leaving the picker, or Return), not as each digit is typed.
        .onChange(of: timeFocus) { old, new in if old != nil, old != new { commitSoon() } }
    }

    private func commitSoon() { Task { await model.commit() } }

    /// The agent's sentence for a refused save, or a problem with the list that no field shows (the limit's and the
    /// window's are beside their rows).
    private var refusal: String? {
        guard let message = model.saveError else { return nil }
        return message == model.edit.uploadLimitProblem || message == model.edit.windowProblem ? nil : message
    }

    /// The limit's explanation is in the section's footer, so the row holds only the controls (Task 17c, as P6 has it
    /// for General).
    @ViewBuilder private var limit: some View {
        LabeledContent("Upload limit for this Mac") {
            MacLimitField(
                name: "Upload limit for this Mac", amount: $model.fields.limitAmount, kind: model.fields.limitKind,
                onKind: { kind in Task { await model.setLimitKind(kind) } }, onCommit: { commitSoon() })
                .disabled(model.asking)
        }
        if let problem = model.edit.uploadLimitProblem {
            SeverityText(problem)
        }
        if model.asking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for your answer to the Location question…").foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        if let note = model.percentNote {
            SeverityText(note, severity: .warning, font: .subheadline)
        }
    }

    /// The current network's measured upload speed and its age, with Test now. The time-dependent words ("today") are
    /// worked out again each minute.
    @ViewBuilder private var speed: some View {
        TimelineView(.everyMinute) { timeline in
            LabeledContent {
                Button("Test now") { Task { await model.testNow() } }
                    .disabled(model.testing)
            } label: {
                Text(model.edit.speedLine(model.uploadSpeed, now: timeline.date, calendar: .current))
            }
        }
        if let error = model.testError {
            SeverityText(error)
        }
    }

    /// "Only limit during  [Weekdays] [8:00 am] to [6:00 pm]". Shown whenever there is a limit.
    @ViewBuilder private var window: some View {
        LabeledContent {
            HStack(spacing: 6) {
                LimitDaysPicker(days: $model.fields.windowDays)
                TimeOfDayPicker(name: "Window start", minute: $model.fields.windowStart)
                    .focused($timeFocus, equals: .start)
                    .onSubmit { commitSoon() }
                Text("to").foregroundStyle(.secondary)
                TimeOfDayPicker(name: "Window end", minute: $model.fields.windowEnd)
                    .focused($timeFocus, equals: .end)
                    .onSubmit { commitSoon() }
            }
            .disabled(!model.fields.windowEnabled)
        } label: {
            Toggle("Only limit during", isOn: $model.fields.windowEnabled)
        }
        if let problem = model.edit.windowProblem {
            SeverityText(problem)
        }
    }

    /// What a backup starting now would get as the limit, and when that changes.
    private var now: some View {
        TimelineView(.everyMinute) { timeline in
            Text(model.edit.nowLine(status: model.uploadSpeed, at: timeline.date, calendar: .current))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var wiFiList: some View {
        if model.fields.wiFiNames.isEmpty {
            Text("No networks").foregroundStyle(.secondary)
        }
        ForEach(model.fields.wiFiNames, id: \.self) { name in
            HStack {
                Text(name)
                Spacer()
                Button("Remove") { Task { await model.remove(name) } }
                    .controlSize(.small)
                    .accessibilityLabel("Remove \(name)")
            }
        }
    }

    private var blocked: Bool { model.access.addStep == .blocked }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PlainTextField(title: "Network name", text: $model.newName, onSubmit: { Task { await model.addName() } })
                Button("Add") { Task { await model.addName() } }
                    .disabled(model.newName.isEmpty || model.newNameProblem != nil || model.asking)
            }
            // Also while the Location question is up, so the name added is the one submitted.
            .disabled(blocked || model.asking)
            if model.asking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your answer to the Location question…").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if let problem = model.newNameProblem ?? model.addNote {
                SeverityText(problem)
            }
        }
    }

    @ViewBuilder private var accessNote: some View {
        let access = model.access
        if let note = access.note(listed: model.fields.wiFiNames.count) {
            HStack(alignment: .firstTextBaseline) {
                if access.addStep == .blocked {
                    SeverityText(note, severity: .warning, font: .subheadline)
                } else {
                    Text(note).explanatoryNote()
                }
                if access.opensSystemSettings {
                    Spacer()
                    Button("Open System Settings") { NSWorkspace.shared.open(NetworkPane.locationServicesURL) }
                        .controlSize(.small)
                }
            }
        }
    }
}
