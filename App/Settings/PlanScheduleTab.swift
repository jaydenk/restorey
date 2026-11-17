import RestoreyCore
import SwiftUI

/// A plan's Schedule tab (UI design §6.2): how often, the battery rule, and the plan's own upload limit (none by
/// default). The hotspot and Low Data Mode rule is Mac-wide, in Settings → Network.
struct PlanScheduleTab: View {
    @Bindable var model: PlanEditModel
    /// The plan as the agent last reported it: its last backup and next run, for the line under the interval.
    let status: PlanStatus

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("Back up")
                VStack(alignment: .leading, spacing: 4) {
                    IntervalPicker(hours: $model.fields.schedule.intervalHours)
                    scheduleCaption
                }
            }
            GridRow {
                Text("On battery")
                BatteryPicker(rule: $model.fields.schedule.battery)
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Upload limit")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        PlainTextField(title: "None", text: $model.fields.uploadLimit).frame(width: 70)
                        Text("MB/s").foregroundStyle(.secondary)
                    }
                    if let problem = model.edit.uploadLimitProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    Text(limitNote)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Last backup at 14:16 · next at 15:16" for the saved schedule (`MenuPresentation.scheduleCaption`, Task 16a). The
    /// times move on without news from the agent, as the Overview's do.
    private var scheduleCaption: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            Text(MenuPresentation.scheduleCaption(
                status, hasUnsavedEdits: model.edit.isDirty, now: timeline.date, calendar: .autoupdatingCurrent,
                locale: .autoupdatingCurrent))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ruling P2-7: a networked repository also gets its share of the Mac-wide limit, and the smaller wins.
    private var limitNote: String {
        model.saved.repository.needsNetwork
            ? "Empty is no limit. The Mac-wide limit in Settings → Network applies too: a backup gets the smaller of the two."
            : "Empty is no limit."
    }
}
