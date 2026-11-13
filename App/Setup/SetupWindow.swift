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
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        .frame(minHeight: 340, alignment: .topLeading)
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
