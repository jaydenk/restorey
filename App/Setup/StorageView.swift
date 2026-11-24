import AppKit
import RestoreyCore
import SwiftUI

/// Setup step 2, "Where backups go" (mockup step 2, UI design §4): B2 (the default), S3 or another restic
/// location, with the provider's page on making a bucket and a key. "Check" saves the plan and asks the agent
/// what is at the address (`SetupModel.check`). A field's sentence shows once something is typed in it; Check
/// waits until every field reads.
struct StorageView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FillingSegmentedControl(
                name: "Storage", options: StorageForm.Kind.allCases.map { ($0, $0.title) },
                selection: Binding(get: { model.storage.kind }, set: { model.storage.choose($0) }))
            .disabled(model.working)

            switch model.storage.kind {
            case .b2, .s3: BucketFields(model: model)
            case .folder: FolderFields(model: model)
            case .other: OtherLocationFields(model: model)
            }
            if let link = model.storage.kind.helpLink {
                Link("\(link.title) ↗", destination: link.url).font(.callout)
            }
            SetupStepStatus(model: model)
            Spacer(minLength: 12)
            SetupButtonRow {
                if model.working {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
                Button("Check") { Task { await model.check() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || !model.storage.isValid)
            }
        }
        .task { await model.loadPlan() }
    }
}

/// B2 and S3: endpoint, bucket and folder, and the two keys.
private struct BucketFields: View {
    @Bindable var model: SetupModel

    var body: some View {
        let form = model.storage
        let b2 = form.kind == .b2
        SetupField(label: "Endpoint", problem: shown(form.endpoint, form.endpointProblem)) {
            PlainTextField(
                title: b2 ? StorageForm.b2EndpointPlaceholder : StorageForm.awsEndpoint, text: $model.storage.endpoint)
        }
        HStack(alignment: .top) {
            SetupField(label: "Bucket", problem: shown(form.bucket, form.bucketProblem)) {
                PlainTextField(title: "my-backups", text: $model.storage.bucket)
            }
            SetupField(label: "Folder (optional)", problem: form.prefixProblem) {
                PlainTextField(title: "macbook", text: $model.storage.prefix)
            }
        }
        ForEach(form.secretKeys(planID: model.planID), id: \.account) { key in
            SetupField(label: StorageForm.label(for: key, kind: form.kind).capitalisedFirst) {
                SecretField(title: StorageForm.label(for: key, kind: form.kind).capitalisedFirst, text: secret(key))
            }
        }
        if model.keepsSavedSecrets {
            Text("Leave a key empty to keep the one already saved.").explanatoryNote()
        }
    }

    private func secret(_ key: SecretKey) -> Binding<String> {
        Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) })
    }
}

/// A folder or drive on this Mac, chosen with the open panel. Laid out like the other storage pages: a labelled field
/// (read-only here, showing the chosen path) with Choose… beside it, as Key ID has Show (owner's live check, 24 Nov
/// 2026: the bare "No folder chosen" line and its far-off button didn't line up with anything). Whether the folder is
/// empty or holds a repository is what "Check" finds out (`SetupModel.check`).
private struct FolderFields: View {
    @Bindable var model: SetupModel

    var body: some View {
        SetupField(label: "Folder or drive") {
            HStack(spacing: 8) {
                ChosenPathField(path: model.storage.folderPath, placeholder: "No folder chosen")
                Button("Choose…") { choose() }
                    .disabled(model.working)
            }
        }
        Text("An empty folder, or one that holds a restic repository.").explanatoryNote()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the backups go: an empty folder, or one that holds a restic repository."
        Task { @MainActor in
            guard await panel.presentForKeyWindow() == .OK, let url = panel.url else { return }
            model.storage.folderPath = url.standardizedFileURL.path
        }
    }
}

/// Another restic location: the repository string and any environment variables it needs (names in the plan,
/// values in the keychain).
private struct OtherLocationFields: View {
    @Bindable var model: SetupModel

    var body: some View {
        let form = model.storage
        SetupField(label: "Repository", problem: shown(form.repository, form.repositoryProblem)) {
            PlainTextField(title: "sftp:nas:/restic", text: $model.storage.repository)
        }
        Text("Any location restic understands, such as sftp:nas:/restic.")
            .explanatoryNote()
        if !form.environment.isEmpty {
            Text("Environment variables").font(.callout).foregroundStyle(.secondary)
        }
        ForEach($model.storage.environment) { $row in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    PlainTextField(title: "Name", text: $row.name).frame(width: 190)
                    SecretField(title: "Value", text: value(row))
                    Button {
                        // `row` reads through the binding into `model.storage`: take the id first, or the
                        // removal's predicate reads `storage` while it is being changed (an exclusivity trap).
                        let id = row.id
                        model.setEnvironmentValue("", for: id)
                        model.storage.environment.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(row.name.isEmpty ? "variable" : row.name)")
                }
                if !row.name.isEmpty, let problem = form.environmentProblem(row) {
                    SeverityText(problem)
                }
            }
        }
        Button("Add Environment Variable") { model.storage.environment.append(StorageForm.EnvironmentRow()) }
            .disabled(model.working)
    }

    /// By the row's id, not its name: the name can still change, and the value must follow the row.
    private func value(_ row: StorageForm.EnvironmentRow) -> Binding<String> {
        Binding(get: { model.environmentValue(row.id) }, set: { model.setEnvironmentValue($0, for: row.id) })
    }
}

/// A field's sentence once something is typed: an empty form isn't a list of complaints.
private func shown(_ text: String, _ problem: String?) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : problem
}

extension String {
    /// "key ID" → "Key ID".
    var capitalisedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A read-only field showing a chosen path: the same bezel and height as the editable fields beside it, selectable so
/// the path can be copied, and truncated in the middle so both the volume and the folder's name stay visible.
private struct ChosenPathField: NSViewRepresentable {
    let path: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        TextFieldSupport.configure(field, title: placeholder)
        field.isEditable = false
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = path
        field.toolTip = path.isEmpty ? nil : path
    }
}
