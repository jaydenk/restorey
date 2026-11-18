import RestoreyCore
import SwiftUI

// The pieces of a plan's page in Settings → Plans around its tabs: the stop and new-kit banners, the save bar, and an
// unfinished plan's page. Deleting a plan is the list's − (`PlansPane`), as a settings list of things has it.

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
                SeverityIcon(severity: .warning)
            }
            Spacer()
            Button(BannerAction.saveRecoveryKit(planID).buttonTitle) { context.showRecoveryKit(planID) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// "Stopped" and the agent's reason (the menu's plan line, live finding 3): nothing runs until the cause is fixed,
/// a wrong password typed in Storage, say.
struct StopBanner: View {
    let note: PlanNote

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.headline)
                if let detail = note.detail {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            SeverityIcon(severity: .error)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// The edits' state and the buttons: the pause warning, the first problem or the save's sentence, Revert and Save (⌘S)
/// on the right. Save isn't the default button: Return belongs to the fields.
struct SaveBar: View {
    @Bindable var model: PlanEditModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if model.edit.pausesBackups {
                    SeverityText(PlanEdit.pauseWarning, severity: .warning)
                }
                if let error = model.saveError {
                    SeverityText(error)
                } else if model.edit.isDirty, let problem = model.edit.problem {
                    SeverityText(problem)
                }
            }
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

/// An unfinished plan: setup is still making it, so it is finished there (or deleted with the list's −).
struct UnfinishedPlanView: View {
    let plan: Plan
    let context: SettingsContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.name).pageTitle()
            Label {
                Text("Setup not finished")
            } icon: {
                SeverityIcon(severity: .warning)
            }
            .font(.headline)
            Text("Finish setting it up to start backing up.")
            HStack {
                Spacer()
                Button(BannerAction.finishSetup(plan.id).buttonTitle) { context.finishSetup() }
            }
            Spacer()
        }
    }
}
