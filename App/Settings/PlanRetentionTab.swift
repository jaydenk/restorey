import RestoreyCore
import SwiftUI

/// A plan's Retention tab (UI design §6.2; "Keep" until Task 17c), as a grouped form: the four counts, each with a
/// stepper, the prune switch, and for an adopted repository how often old snapshots are tidied (product spec §5.6:
/// `forget` and `prune` lock the whole repository, so a repository other clients write to is tidied daily and never
/// pruned by default), and below them the plan's earlier snapshots, which retention leaves alone unless the user
/// applies it (`EarlierSnapshotsSection`, Task 14b).
struct PlanRetentionTab: View {
    @Bindable var model: PlanEditModel
    let connection: AgentConnection

    private var adopted: Bool { model.saved.origin == .adopted }

    var body: some View {
        Form {
            Section {
                LabeledContent("Hourly") { RetentionCountField(name: "Hourly", text: $model.fields.schedule.hourly) }
                LabeledContent("Daily") { RetentionCountField(name: "Daily", text: $model.fields.schedule.daily) }
                LabeledContent("Weekly") { RetentionCountField(name: "Weekly", text: $model.fields.schedule.weekly) }
                LabeledContent("Monthly") { RetentionCountField(name: "Monthly", text: $model.fields.schedule.monthly) }
                if case .failure(let problem) = model.fields.schedule.retention {
                    SeverityText(problem.message)
                }
            } header: {
                Text("Keep")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = RetentionSummary.text(
                        form: model.fields.schedule, cadence: adopted ? model.fields.forgetCadence : .afterEachBackup,
                        locale: .autoupdatingCurrent)
                    {
                        Text(summary).explanatoryNote()
                    }
                    Text("Retention thins only this plan’s snapshots of its current folders from this Mac. Snapshots from other Macs and tools are never touched, and earlier ones only when you apply it below.")
                        .explanatoryNote()
                }
            }
            Section {
                Toggle("Remove unused data about once a week (prune)", isOn: $model.fields.pruneEnabled)
                    // In a grouped form the switch's own label is drawn apart from it (live finding 4).
                    .accessibilityLabel("Remove unused data about once a week (prune)")
                if adopted {
                    Picker("Tidy old snapshots", selection: $model.fields.forgetCadence) {
                        Text("After each backup").tag(ForgetCadence.afterEachBackup)
                        Text("Once a day").tag(ForgetCadence.daily)
                    }
                    .accessibilityLabel("Tidy old snapshots")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if adopted {
                        Text("Pruning locks the whole repository while it runs, so other Macs or tools backing up to it wait or fail. Restorey never breaks another program’s lock.")
                            .explanatoryNote()
                        Text("Tidying locks the repository too, so a shared repository is tidied once a day.")
                            .explanatoryNote()
                    }
                    Text(RetentionSummary.weeklyCheckNote)
                        .explanatoryNote()
                }
            }
            EarlierSnapshotsSection(plan: model.saved, unsavedEdits: model.edit.isDirty, connection: connection)
        }
        .formStyle(.grouped)
    }
}
