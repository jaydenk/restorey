import RestoreyCore
import SwiftUI

/// A plan's Keep tab (UI design §6.2): retention, the prune switch, and for an adopted repository how often old
/// snapshots are tidied (product spec §5.6: `forget` and `prune` lock the whole repository, so a repository other
/// clients write to is tidied daily and never pruned by default).
struct PlanKeepTab: View {
    @Bindable var model: PlanEditModel

    private var adopted: Bool { model.saved.origin == .adopted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Keep")
                    RetentionFields(form: $model.fields.schedule)
                }
            }
            Text("The newest snapshot of each hour, day, week and month, up to these counts. Only this plan's own snapshots from this Mac are thinned: those of other Macs, other tools and from before Restorey used the repository are never touched.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Remove unused data about once a week (prune)", isOn: $model.fields.pruneEnabled)
            if adopted {
                Text("Pruning locks the whole repository while it runs: other Macs or tools backing up to it wait, or fail if they can't. Restorey never breaks another program's lock.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Tidy old snapshots", selection: $model.fields.forgetCadence) {
                    Text("After each backup").tag(ForgetCadence.afterEachBackup)
                    Text("Once a day").tag(ForgetCadence.daily)
                }
                .fixedSize()
                Text("Tidying (restic forget) locks the repository too, so a repository other clients use is tidied once a day.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
