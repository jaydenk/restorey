#if DEBUG
import AppKit
import RestoreyCore
import SwiftUI

/// Opens the Debug-only developer window from the status item's "Developer…" item.
@MainActor
final class DeveloperWindowController: NSObject, NSWindowDelegate {
    private let model: DeveloperModel
    private var window: NSWindow?

    init(supervisor: AgentSupervisor, identity: Identity, planDeleted: @escaping (UUID) -> Void) {
        model = DeveloperModel(supervisor: supervisor, identity: identity, planDeleted: planDeleted)
        super.init()
    }

    /// The form's secrets don't outlive the window.
    func windowWillClose(_ notification: Notification) {
        model.clearSecrets()
        WindowActivation.windowClosed(.developer)
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
        if let window { WindowActivation.bringForward(window, as: .developer) }
    }
}

struct DeveloperView: View {
    @Bindable var model: DeveloperModel
    @State private var confirmingCreate = false
    @State private var confirmingDelete = false

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
                LabeledContent("Name") { PlainTextField(title: "Name", text: $model.name) }
                LabeledContent("Host label") { PlainTextField(title: "Host label", text: $model.hostLabel) }
                Picker("Provider", selection: $model.kind) {
                    ForEach(DeveloperModel.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.kind == .local {
                    LabeledContent("Repository path") {
                        PlainTextField(title: "Repository path", text: $model.localPath)
                    }
                } else {
                    LabeledContent("Endpoint") { PlainTextField(title: "Endpoint", text: $model.endpoint) }
                    LabeledContent("Bucket") { PlainTextField(title: "Bucket", text: $model.bucket) }
                    LabeledContent("Prefix") { PlainTextField(title: "Prefix", text: $model.prefix) }
                    LabeledContent("Key ID") { SecretField(title: "Key ID", text: $model.keyID) }
                    LabeledContent("Secret") { SecretField(title: "Secret", text: $model.secret) }
                }
                LabeledContent("Repository password") {
                    SecretField(title: "Repository password", text: $model.repositoryPassword)
                }
                if model.selectedPlanID == nil {
                    Toggle("Existing repository (adopt, never prune)", isOn: $model.adoptExisting)
                }
                if model.selectedPlanID != nil {
                    LabeledContent("Check-in URL", value: model.checkInSummary)
                }
                let checkInTitle = model.selectedPlan?.hasCheckInURL == true ? "New check-in URL" : "Check-in URL (optional)"
                LabeledContent(checkInTitle) { SecretField(title: checkInTitle, text: $model.checkInURL) }
                if model.selectedPlan?.hasCheckInURL == true {
                    Toggle("Remove check-in URL", isOn: $model.removeCheckInURL)
                }
                LabeledContent("Sources") { SourcesEditor(sources: $model.sources, repository: model.selectedPlan?.repository) }
                LabeledContent("Excluded file types") { FileTypesEditor(types: $model.fileTypes) }
            }
            if model.selectedPlanID != nil {
                Text("Leave a secret or the check-in URL empty to keep the saved one. Use \"Remove check-in URL\" to remove it.")
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
                Button("Request Location") { model.requestLocation() }
                Button("Delete plan…", role: .destructive) { confirmingDelete = true }
                    .disabled(model.selectedPlan == nil)
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
        .confirmationDialog(
            "Delete the plan \"\(model.selectedPlan?.name ?? "")\"?", isPresented: $confirmingDelete
        ) {
            Button("Delete plan", role: .destructive) { model.deletePlan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings, saved passwords and keys, and history are removed. The repository and its snapshots aren't touched.")
        }
    }
}
#endif
