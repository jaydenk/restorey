import RestoreyCore
import SwiftUI

/// A plan's Keep tab (UI design §6.2): retention, the prune switch, and for an adopted repository how often old
/// snapshots are tidied (product spec §5.6: `forget` and `prune` lock the whole repository, so a repository other
/// clients write to is tidied daily and never pruned by default), and below them the plan's earlier snapshots, which
/// retention leaves alone unless the user applies it (`EarlierSnapshotsSection`, Task 14b).
struct PlanKeepTab: View {
    @Bindable var model: PlanEditModel
    let connection: AgentConnection

    private var adopted: Bool { model.saved.origin == .adopted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Keep")
                    RetentionFields(form: $model.fields.schedule)
                }
            }
            if let summary = RetentionSummary.text(
                form: model.fields.schedule, cadence: adopted ? model.fields.forgetCadence : .afterEachBackup,
                locale: .autoupdatingCurrent)
            {
                Text(summary).explanatoryNote()
            }
            Text("Retention thins only this plan’s snapshots of its current folders from this Mac. Snapshots from other Macs and tools are never touched, and earlier ones only when you apply it below.")
                .explanatoryNote()

            Toggle("Remove unused data about once a week (prune)", isOn: $model.fields.pruneEnabled)
            if adopted {
                Text("Pruning locks the whole repository while it runs, so other Macs or tools backing up to it wait or fail. Restorey never breaks another program’s lock.")
                    .explanatoryNote()
                Picker("Tidy old snapshots", selection: $model.fields.forgetCadence) {
                    Text("After each backup").tag(ForgetCadence.afterEachBackup)
                    Text("Once a day").tag(ForgetCadence.daily)
                }
                .fixedSize()
                Text("Tidying locks the repository too, so a shared repository is tidied once a day.")
                    .explanatoryNote()
            }
            Text(RetentionSummary.weeklyCheckNote)
                .explanatoryNote()
            Divider().padding(.vertical, 4)
            EarlierSnapshotsSection(plan: model.saved, unsavedEdits: model.edit.isDirty, connection: connection)
        }
    }
}
