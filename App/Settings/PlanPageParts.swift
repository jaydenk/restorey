import RestoreyCore
import SwiftUI

// The pieces of a plan's page in Settings → Plans around its tabs: the new-kit banner, the save bar, Delete Plan…,
// and an unfinished plan's page.

/// "New recovery kit needed" (the menu's banner, UI design §6.2): backups wait until the new kit is confirmed.
struct NewKitBanner: View {
    let planID: UUID
    let context: SettingsContext

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New recovery kit needed").font(.headline)
                    Text("Save the new kit so backups can carry on.").foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button(BannerAction.saveRecoveryKit(planID).buttonTitle) { context.showRecoveryKit(planID) }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The edits' state and the buttons: Delete Plan… on the left; the pause warning, the first problem or the save's
/// sentence, Revert and Save (⌘S) on the right. Save isn't the default button: Return belongs to the fields.
struct SaveBar: View {
    @Bindable var model: PlanEditModel
    let planName: String
    let planID: UUID
    let context: SettingsContext
    let deleted: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            DeletePlanButton(planID: planID, planName: planName, context: context, deleted: deleted)
                .disabled(model.saving)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if model.edit.pausesBackups {
                    Label(PlanEdit.pauseWarning, systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
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
            if model.checkingPassword { Text("Checking the password…").font(.callout).foregroundStyle(.secondary) }
            Button("Revert") { model.revert() }
                .disabled(!model.edit.isDirty || model.saving)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.edit.isDirty || model.edit.problem != nil || model.saving)
        }
    }
}

/// Delete Plan… with the developer window's confirmation (the repository and its snapshots aren't touched). The
/// agent removes the plan's settings, keychain items, history and run logs.
struct DeletePlanButton: View {
    let planID: UUID
    let planName: String
    let context: SettingsContext
    let deleted: () -> Void
    @State private var confirming = false
    @State private var deleting = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 6) {
            Button("Delete Plan…", role: .destructive) { confirming = true }
                .disabled(deleting)
            if deleting { ProgressView().controlSize(.small) }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Delete the plan \"\(planName)\"?", isPresented: $confirming) {
            Button("Delete Plan", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings, saved passwords and keys, and history are removed. The repository and its snapshots aren't touched.")
        }
    }

    private func delete() async {
        deleting = true
        problem = nil
        defer { deleting = false }
        switch await context.supervisor.connection.deletePlan(planID) {
        case .success: deleted()
        case .failure(let error): problem = FormValidation.sentence(error.description)
        }
    }
}

/// An unfinished plan: setup is still making it, so it is finished there (or deleted here).
struct UnfinishedPlanView: View {
    let plan: Plan
    let context: SettingsContext
    let deleted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.name).font(.title3.weight(.semibold))
            Label("Setup not finished", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Finish setting it up to start backing up.")
            HStack {
                DeletePlanButton(planID: plan.id, planName: plan.name, context: context, deleted: deleted)
                Spacer()
                Button(BannerAction.finishSetup(plan.id).buttonTitle) { context.finishSetup() }
            }
            Spacer()
        }
        .padding(16)
    }
}
