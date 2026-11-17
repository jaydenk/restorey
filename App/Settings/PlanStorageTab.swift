import RestoreyCore
import SwiftUI

/// A plan's Storage tab (UI design §6.2): the repository address, read-only (a different repository is a new plan);
/// the password and storage keys, which can be replaced (a rotated B2 key, say) and pause backups until a new
/// recovery kit is saved; the host label, with the product spec's new-group warning (§5.4); the pack size,
/// read-only; and "Show Recovery Kit…". A grouped form, the explanations in the sections' footers (Task 17c).
struct PlanStorageTab: View {
    @Bindable var model: PlanEditModel
    let showRecoveryKit: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Repository") {
                    Text(model.saved.repository.resticRepository)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Pack size") {
                    Text(model.saved.packSizeMiB.map { "\($0) MiB" } ?? "restic’s default")
                }
                LabeledContent("Recovery kit") {
                    Button("Show Recovery Kit…", action: showRecoveryKit)
                }
            } footer: {
                Text("A different repository is a new plan: add it with “Add Plan…”.")
                    .explanatoryNote()
            }
            Section {
                ForEach(model.edit.credentialKeys, id: \.account) { key in
                    SecretRow(label: label(key)) {
                        SecretField(title: label(key), text: secret(key))
                    }
                    if key == .repositoryPassword(model.planID), let problem = model.passwordProblem {
                        SeverityText(problem)
                    }
                }
                if let problem = model.edit.keyPairProblem {
                    SeverityText(problem)
                }
            } footer: {
                Text("Leave a field empty to keep what’s saved. Enter the repository password only if it was changed outside Restorey. This doesn’t change the repository’s password, only the one Restorey uses. Saving tries it on the repository first.")
                    .explanatoryNote()
            }
            Section {
                LabeledContent("Host label") {
                    PlainTextField(title: "Host label", text: $model.fields.hostLabel)
                }
                if let problem = model.edit.hostLabelProblem { SeverityText(problem) }
                if let warning = model.edit.hostLabelWarning {
                    SeverityText(warning, severity: .warning)
                }
            } footer: {
                Text("Every backup is recorded under this name (restic’s --host), so renaming the Mac changes nothing.")
                    .explanatoryNote()
            }
        }
        .formStyle(.grouped)
    }

    private func label(_ key: SecretKey) -> String {
        StorageForm.label(for: key, kind: model.edit.storageKind).capitalisedFirst
    }

    private func secret(_ key: SecretKey) -> Binding<String> {
        Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) })
    }
}

/// A form row with a secret's field: its label, then the field and its Show switch at the trailing edge. Laid out by
/// hand, since a grouped form's `LabeledContent` set a value holding a field and a switch under its label instead of
/// beside it (Task 17c, seen in an off-screen render).
struct SecretRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 8)
            field.frame(width: 240)
        }
    }
}
