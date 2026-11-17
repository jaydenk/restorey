import RestoreyCore
import SwiftUI

/// A plan's Storage tab (UI design §6.2): the repository address, read-only (a different repository is a new plan);
/// the password and storage keys, which can be replaced (a rotated B2 key, say) and pause backups until a new
/// recovery kit is saved; the host label, with the product spec's new-group warning (§5.4); the pack size,
/// read-only; and "Show Recovery Kit…".
struct PlanStorageTab: View {
    @Bindable var model: PlanEditModel
    let showRecoveryKit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupField(label: "Repository") {
                Text(model.saved.repository.resticRepository)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A different repository is a new plan: add it with “Add Plan…”.")
                .explanatoryNote()

            ForEach(model.edit.credentialKeys, id: \.account) { key in
                SetupField(label: label(key), problem: key == .repositoryPassword(model.planID) ? model.passwordProblem : nil) {
                    SecretField(title: label(key), text: secret(key))
                }
            }
            if let problem = model.edit.keyPairProblem {
                SeverityText(problem)
            }
            Text("Leave a field empty to keep what’s saved. Enter the repository password only if it was changed outside Restorey. This doesn’t change the repository’s password, only the one Restorey uses. Saving tries it on the repository first.")
                .explanatoryNote()

            Divider()
            SetupField(label: "Host label", problem: model.edit.hostLabelProblem) {
                PlainTextField(title: "Host label", text: $model.fields.hostLabel)
            }
            Text("Every backup is recorded under this name (restic’s --host), so renaming the Mac changes nothing.")
                .explanatoryNote()
            if let warning = model.edit.hostLabelWarning {
                SeverityText(warning, severity: .warning)
            }
            LabeledContent("Pack size") {
                Text(model.saved.packSizeMiB.map { "\($0) MiB" } ?? "restic’s default")
            }
            HStack {
                Spacer()
                Button("Show Recovery Kit…", action: showRecoveryKit)
            }
        }
    }

    private func label(_ key: SecretKey) -> String {
        StorageForm.label(for: key, kind: model.edit.storageKind).capitalisedFirst
    }

    private func secret(_ key: SecretKey) -> Binding<String> {
        Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) })
    }
}
