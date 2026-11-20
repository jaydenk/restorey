import RestoreyCore
import SwiftUI

/// Setup step 4, "Recovery kit" (mockup step 4, UI design §4 and §7): why the kit matters, the kit itself
/// (`RecoveryKitView`: copy each field, Print…, Save as PDF…), where to keep it, and the tick that lets setup go
/// on. The tick is recorded as `SetupProgress.kitSaved`; the agent's confirmation waits for Done's "Start first
/// backup" (`SetupFlow`), so the plan can't run while sources and schedule are chosen.
struct RecoveryKitStepView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RecoveryKitText.why)
                .fixedSize(horizontal: false, vertical: true)
            if model.kitBlockedByStandInPassword {
                SeverityText(
                    "The repository’s password isn’t saved yet, so there’s no kit to show. Go back and create or open the repository first.",
                    severity: .warning, font: .body)
            } else if let kit = model.recoveryKit {
                RecoveryKitView(model: kit)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            }
            Text(RecoveryKitText.keepItSafe)
                .explanatoryNote()
            Toggle(RecoveryKitText.savedTick, isOn: $model.kitSaved)
                .toggleStyle(.checkbox)
                .disabled(!model.canTickKitSaved)
            // Done's Start sends the person back here when the details changed since the tick (Task 9).
            SetupStepStatus(model: model)
            Spacer(minLength: 12)
            HStack {
                if model.kitBlockedByStandInPassword {
                    Button("Back") { model.backToPassword() }
                }
                Spacer()
                Button("Continue") { model.continueFromRecoveryKit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue || model.kitBlockedByStandInPassword)
            }
        }
        .task { await model.openRecoveryKit() }
    }
}
