#if DEBUG
import AppKit
import RestoreyCore
import SwiftUI

/// Opens the Debug-only developer window from the status item's "Developer…" item.
@MainActor
final class DeveloperWindowController: NSObject, NSWindowDelegate {
    private let model: DeveloperModel
    private var window: NSWindow?

    init(supervisor: AgentSupervisor, identity: Identity) {
        model = DeveloperModel(supervisor: supervisor, identity: identity)
        super.init()
    }

    /// The form's secrets don't outlive the window.
    func windowWillClose(_ notification: Notification) {
        model.clearSecrets()
    }

    func show() {
        if window == nil {
            let made = NSWindow(contentViewController: NSHostingController(rootView: DeveloperView(model: model)))
            made.title = "Restorey Developer"
            made.setContentSize(NSSize(width: 980, height: 720))
            made.isReleasedWhenClosed = false
            made.isRestorable = false
            made.delegate = self
            window = made
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DeveloperView: View {
    @Bindable var model: DeveloperModel
    @State private var confirmingCreate = false

    var body: some View {
        HSplitView {
            ScrollView { form.padding() }
                .frame(minWidth: 460)
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent: \(String(describing: model.supervisor.health))").font(.headline)
                Text("Status").font(.headline)
                ScrollView {
                    Text(model.statusJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(minWidth: 360)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Plan", selection: Binding(get: { model.selectedPlanID }, set: { model.load($0) })) {
                Text("New plan").tag(UUID?.none)
                ForEach(model.plans) { plan in Text(plan.name).tag(UUID?.some(plan.id)) }
            }

            Form {
                TextField("Name", text: $model.name)
                TextField("Host label", text: $model.hostLabel)
                Picker("Provider", selection: $model.kind) {
                    ForEach(DeveloperModel.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.kind == .local {
                    TextField("Repository path", text: $model.localPath)
                } else {
                    TextField("Endpoint", text: $model.endpoint)
                    TextField("Bucket", text: $model.bucket)
                    TextField("Prefix", text: $model.prefix)
                    SecureField("Key ID", text: $model.keyID)
                    SecureField("Secret", text: $model.secret)
                }
                SecureField("Repository password", text: $model.repositoryPassword)
                if model.selectedPlanID == nil {
                    Toggle("Existing repository (adopt, never prune)", isOn: $model.adoptExisting)
                }
                SecureField("Check-in URL (optional)", text: $model.checkInURL)
                LabeledContent("Sources (one per line)") {
                    TextEditor(text: $model.sources)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                }
            }
            if model.selectedPlanID != nil {
                Text("Leave the password, key ID or secret empty to keep the saved one. An empty check-in URL removes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading) {
            HStack {
                Button("Save plan") { model.save() }
                Button("Create repository…") { confirmingCreate = true }
                    .disabled(model.createAddress == nil)
                Button("Adopt") { model.adopt() }
                Button("I've saved the recovery details") { model.confirmRecoveryKit() }
            }
            HStack {
                Button("Back Up Now") { model.backUpNow() }
                Button("Pause") { model.pause() }
                Button("Resume") { model.resume() }
                Button("Request notifications") { model.requestNotifications() }
            }
            }
            .disabled(model.working)

            Text(model.output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Create a restic repository at \(model.createAddress ?? "")?", isPresented: $confirmingCreate
        ) {
            Button("Create repository") { model.createRepository() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.createIsS3 {
                Text("If the bucket doesn't exist and your key can create buckets, it will be created.")
            } else {
                Text("The folder will be created if it doesn't exist.")
            }
        }
    }
}
#endif
