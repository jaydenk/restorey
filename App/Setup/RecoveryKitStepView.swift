import RestoreyCore
import SwiftUI

/// Setup step 4, "Recovery kit" (mockup step 4, UI design §4 and §7). Task 13 puts the kit itself here (its
/// fields, copy, print, save as PDF); until then this is the step's frame: why the kit matters, and the tick
/// that lets setup go on. The tick is recorded as `SetupProgress.kitSaved`; the agent's confirmation waits for
/// Done's "Start first backup" (`SetupFlow`), so the plan can't run while sources and schedule are chosen.
struct RecoveryKitStepView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Without this you can't restore if this Mac is lost. It's the address, password and keys, and how to restore without Restorey.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The recovery kit appears here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Store it off this Mac (a password manager, or paper). Restorey never saves a copy on the Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("I've saved it somewhere other than this Mac", isOn: $model.kitSaved)
                .toggleStyle(.checkbox)
            Spacer(minLength: 12)
            SetupButtonRow {
                Button("Continue") { model.continueFromRecoveryKit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
        }
        .task { await model.loadPlan() }
    }
}
