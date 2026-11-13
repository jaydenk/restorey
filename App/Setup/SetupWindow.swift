import RestoreyCore
import SwiftUI

/// The setup window's content: the step line, then the current step's screen (mockup `v0.1-setup-flow.html`).
struct SetupWindow: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.heading)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let configError = model.configError {
                // The menu's wording (`MenuPresentation`); setup waits for a status that lists the plan again.
                Label("Restorey can't read its settings: \(configError)", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Setup carries on when the settings can be read again.")
                    .foregroundStyle(.secondary)
                stepView
            } else if model.planMissing {
                PlanMissingView(model: model)
            } else {
                stepView
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        .frame(minHeight: 340, alignment: .topLeading)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .moveToApplications:
            MoveToApplicationsView(model: model)
        case .permissions:
            PermissionsView(model: model)
        case .storage:
            StorageView(model: model)
        case .password:
            PasswordView(model: model)
        case .recoveryKit:
            RecoveryKitStepView(model: model)
        case .sources:
            SourcesView(model: model)
        case .schedule:
            ScheduleView(model: model)
        case .done:
            DoneView(model: model)
        }
    }
}

/// The plan this setup was building is gone from the agent (deleted elsewhere, say): say so, and start again
/// at the storage step rather than leave the step waiting for it.
private struct PlanMissingView: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The plan this setup was making is no longer there.", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("It may have been deleted elsewhere, in Settings or another window. Start again from where backups go; nothing has been backed up for it.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            SetupButtonRow {
                Button("Start Again") { model.startAgain() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The screens' Continue-style button row, right-aligned.
struct SetupButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Spacer()
            content
        }
    }
}

/// A labelled field with the sentence for its problem underneath, when there is one.
struct SetupField<Field: View>: View {
    let label: String
    var problem: String?
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            field
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The step's last error, and the spinner while its action runs.
struct SetupStepStatus: View {
    let model: SetupModel

    var body: some View {
        if let error = model.stepError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
