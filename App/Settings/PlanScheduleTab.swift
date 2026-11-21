import RestoreyCore
import SwiftUI

/// A plan's Schedule tab (UI design §6.2), as a grouped form: how often, the battery rule and the plan's own upload
/// limit (none by default); then its alerts, the check-in URL and the "no successful backup in N days" threshold, which
/// were a tab of their own until Task 17c brought the tabs down to the HIG's six. The hotspot and Low Data Mode rule is
/// Mac-wide, in Settings → Network. Notifications are always on, the only alert channel on the Mac. Changing the
/// check-in URL doesn't need a new recovery kit: it isn't needed to restore.
struct PlanScheduleTab: View {
    @Bindable var model: PlanEditModel
    /// The plan as the agent last reported it: its last backup and next run, for the line under the interval.
    let status: PlanStatus

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    IntervalPicker(hours: $model.fields.schedule.intervalHours)
                } label: {
                    Text("Back up")
                    scheduleCaption
                }
                LabeledContent("On battery") {
                    BatteryPicker(rule: $model.fields.schedule.battery)
                }
                LabeledContent("Upload limit") {
                    UploadLimitField(name: "Upload limit", text: $model.fields.uploadLimit, unit: $model.uploadLimitUnit)
                }
                if let problem = model.edit.uploadLimitProblem {
                    SeverityText(problem)
                }
            } footer: {
                Text(limitNote).explanatoryNote()
            }
            Section {
                checkInURL
                if let problem = model.edit.checkInProblem {
                    SeverityText(problem)
                }
                Stepper(value: $model.fields.noSuccessAlertDays, in: 1...30) {
                    Text("Alert when there’s no successful backup in \(days) \(days == 1 ? "day" : "days")")
                }
            } header: {
                Text("Alerts")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ScheduleForm.checkInExplanation).explanatoryNote()
                    Text("Notifications are always on: they’re how Restorey tells you about a problem on this Mac.")
                        .explanatoryNote()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "Last backup at 14:16 · next at 15:16" for the saved schedule (`MenuPresentation.scheduleCaption`, Task 16a), as
    /// the interval row's second line. The times move on without news from the agent, as the Overview's do.
    private var scheduleCaption: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            Text(MenuPresentation.scheduleCaption(
                status, hasUnsavedScheduleEdits: model.edit.scheduleIsDirty, now: timeline.date, calendar: .autoupdatingCurrent,
                locale: .autoupdatingCurrent))
                .explanatoryNote()
        }
    }

    /// The optional check-in URL (`CheckInURLValue`, setup's too) as a form row. The saved note and Remove take the
    /// width they need; the field has the secret row's width.
    @ViewBuilder private var checkInURL: some View {
        let key = SecretKey.checkInURL(model.planID)
        let showsField = CheckInURLValue.showsField(
            saved: model.saved.hasCheckInURL, remove: model.fields.removeCheckInURL)
        SecretRow(label: CheckInURLValue.label, fieldWidth: showsField ? secretRowFieldWidth : nil) {
            CheckInURLValue(
                saved: model.saved.hasCheckInURL, remove: $model.fields.removeCheckInURL,
                text: Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) }))
        }
    }

    private var days: Int { model.fields.noSuccessAlertDays }

    /// Ruling P2-7: a networked repository also gets its share of the Mac-wide limit, and the smaller wins.
    private var limitNote: String {
        model.saved.repository.needsNetwork
            ? "Empty is no limit. The Mac-wide limit in Settings → Network applies too: a backup gets the smaller of the two."
            : "Empty is no limit."
    }
}
