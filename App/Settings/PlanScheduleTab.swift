import RestoreyCore
import SwiftUI

/// A plan's Schedule tab (UI design §6.2): how often, the battery rule, and the plan's own upload limit (none by
/// default). The hotspot and Low Data Mode rule is Mac-wide, in Settings → Network.
struct PlanScheduleTab: View {
    @Bindable var model: PlanEditModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("Back up")
                IntervalPicker(hours: $model.fields.schedule.intervalHours)
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

    /// Ruling P2-7: a networked repository also gets its share of the Mac-wide limit, and the smaller wins.
    private var limitNote: String {
        model.saved.repository.needsNetwork
            ? "Empty is no limit. The Mac-wide limit in Settings → Network applies too: a backup gets the smaller of the two."
            : "Empty is no limit."
    }
}
