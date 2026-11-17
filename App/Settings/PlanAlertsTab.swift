import RestoreyCore
import SwiftUI

/// A plan's Alerts tab (UI design §6.2, v0.1 scope §3): the check-in URL and the "no successful backup in N days"
/// threshold. Notifications are always on, the only alert channel on the Mac. Changing the check-in URL doesn't
/// need a new recovery kit: it isn't needed to restore.
struct PlanAlertsTab: View {
    @Bindable var model: PlanEditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CheckInURLField(
                saved: model.saved.hasCheckInURL, remove: $model.fields.removeCheckInURL, text: checkInURL,
                problem: model.edit.checkInProblem)
            Divider()
            Stepper(value: $model.fields.noSuccessAlertDays, in: 1...30) {
                Text("Alert when there’s no successful backup in \(days) \(days == 1 ? "day" : "days")")
            }
            Text("Notifications are always on: they’re how Restorey tells you about a problem on this Mac.")
                .explanatoryNote()
        }
    }

    private var days: Int { model.fields.noSuccessAlertDays }

    /// The secret as typed, straight into the edit.
    private var checkInURL: Binding<String> {
        let key = SecretKey.checkInURL(model.planID)
        return Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) })
    }
}
