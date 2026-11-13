import RestoreyCore
import SwiftUI

/// The setup window's content: the step line, then the current step's screen (mockup `v0.1-setup-flow.html`).
/// Storage to Done are Task 12's.
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
            case .storage, .password, .recoveryKit, .sources, .schedule, .done:
                Text("This step isn't built yet.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .topLeading)
        .frame(minHeight: 300, alignment: .topLeading)
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
