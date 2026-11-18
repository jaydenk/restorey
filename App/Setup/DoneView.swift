import RestoreyCore
import SwiftUI

/// Setup step 7, "Done" (mockup's last window, UI design §4): "Start first backup" saves anything left,
/// confirms the recovery kit and starts the run (`SetupModel.startFirstBackup`), then the run's live progress
/// from the agent's statuses, worded as the menu words it. Closing the window leaves the backup running; the
/// menu bar shows it.
struct DoneView: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = model.firstBackup {
                FirstBackupLine(progress: progress)
                Text(progress.finished
                    ? "From now on Restorey backs up by itself. The menu bar icon shows how it’s going."
                    : "You can close this window. The backup keeps going in the background, and the menu bar icon shows how it’s going.")
                    .explanatoryNote()
            } else if let plan = model.plan {
                Text("Ready for the first backup.").font(.headline)
                PlanSummary(plan: plan)
                Text("The first backup reads every file, so it can take hours. Restorey backs up \(ScheduleForm.title(hours: plan.intervalHours).lowercased()) after that.")
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = model.earlierRemovalSummary {
                    Text(summary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            SetupStepStatus(model: model)
            Spacer(minLength: 12)
            SetupButtonRow {
                if model.firstBackup != nil {
                    Button("Close") { model.closeSetupWindow() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    if model.working { ProgressView().controlSize(.small) }
                    Button("Start First Backup") { Task { await model.startFirstBackup() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.working || model.plan == nil)
                }
            }
        }
        .task { await model.loadPlan() }
    }
}

private struct FirstBackupLine: View {
    let progress: FirstBackupProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A problem has its symbol; the title stays in the label colour.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let severity = progress.severity { SeverityIcon(severity: severity) }
                Text(progress.title)
            }
            .font(.headline)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else if !progress.finished {
                ProgressView().progressViewStyle(.linear)
            }
            if let detail = progress.detail {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where and what, before Start: enough to notice a wrong choice.
private struct PlanSummary: View {
    let plan: Plan

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("To").foregroundStyle(.secondary)
                // The plan's name, not the raw location, which may carry a user name or password.
                Text(plan.name).lineLimit(1).truncationMode(.middle)
            }
            GridRow {
                Text("From").foregroundStyle(.secondary)
                Text(plan.sources.map { FormValidation.displayPath($0) }.joined(separator: ", "))
                    .lineLimit(2).truncationMode(.middle)
            }
            GridRow {
                Text("As").foregroundStyle(.secondary)
                Text(plan.hostLabel)
            }
        }
    }
}

private extension Plan {
    var intervalHours: Int {
        switch schedule {
        case .interval(let seconds): max(1, seconds / 3600)
        }
    }
}
