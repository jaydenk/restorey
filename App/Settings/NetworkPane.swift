import AppKit
import RestoreyCore
import SwiftUI

/// Settings → Network (UI design §6.3, product spec §5.5, Rulings P2-6 to P2-8 and R69): the Mac-wide upload limit,
/// the hotspot and Low Data Mode rule, and the Wi-Fi networks to skip, with Revert and Save as a plan's tabs have
/// them. Every decision is `NetworkEdit`'s and `WiFiNameAccess`'s; `NetworkEditModel` does the calls.
///
/// Location permission is asked for only when the user first adds a network, and what the list says without it is
/// read again whenever Restorey comes back to the front (the user may have changed it in System Settings).
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
                NetworkForm(model: model)
            } else if let configError = status?.configError {
                unavailable("Restorey can't read its settings: \(FormValidation.sentence(configError))")
            } else if status != nil {
                // An agent from before the Mac-wide rules (schema 3) sends none.
                unavailable("The background agent didn't send the network settings. Restart it from General.")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: status?.network, initial: true) { _, network in
            guard let network else { return }
            if let model = slot.model {
                model.rebase(on: network)
            } else {
                slot.model = NetworkEditModel(settings: network, supervisor: supervisor)
            }
        }
        .task { await slot.model?.reread() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await slot.model?.reread() }
        }
    }

    private func unavailable(_ sentence: String) -> some View {
        Label(sentence, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NetworkForm: View {
    @Bindable var model: NetworkEditModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    limit
                    Toggle("Skip on a hotspot or in Low Data Mode", isOn: $model.fields.skipOnConstrainedNetwork)
                        // In a grouped form the switch's own label is drawn apart from it (live finding 4).
                        .accessibilityLabel("Skip on a hotspot or in Low Data Mode")
                } footer: {
                    Text("These rules apply only to plans that back up to another machine, such as S3, B2 or a restic "
                        + "server. A backup to a folder or drive on this Mac is never skipped or limited by them.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Skip on these Wi-Fi networks") {
                    wiFiList
                    addRow
                    accessNote
                }
            }
            .formStyle(.grouped)
            Divider()
            saveBar.padding(12)
        }
    }

    private var limit: some View {
        LabeledContent("Upload limit for this Mac") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    PlainTextField(title: "None", text: $model.fields.uploadLimit)
                        .frame(width: 70)
                        .accessibilityLabel("Upload limit for this Mac, in MB/s")
                    Text("MB/s").foregroundStyle(.secondary)
                }
                if let problem = model.edit.uploadLimitProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Text("Empty is no limit. Backups that upload at the same time share it, and a plan's own limit "
                    + "applies too: a backup gets the smaller of the two.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
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
                Button("Remove") { model.remove(name) }
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
            .disabled(blocked)
            if model.asking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your answer to the Location question…").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if let problem = model.newNameProblem ?? model.addNote {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var accessNote: some View {
        let access = model.access
        if let note = access.note(listed: model.fields.wiFiNames.count) {
            HStack(alignment: .firstTextBaseline) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(access.opensSystemSettings ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if access.opensSystemSettings {
                    Spacer()
                    Button("Open System Settings") { NSWorkspace.shared.open(NetworkPane.locationServicesURL) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// The first problem or the save's sentence, Revert and Save (⌘S), as a plan's page has them.
    private var saveBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Group {
                if let error = model.saveError {
                    Text(error).foregroundStyle(.red)
                } else if model.edit.isDirty, let problem = model.edit.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            if model.saving { ProgressView().controlSize(.small) }
            Button("Revert") { model.revert() }
                .disabled(!model.edit.isDirty || model.saving)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.edit.isDirty || model.edit.problem != nil || model.saving)
        }
    }
}
