import RestoreyCore
import SwiftUI

/// Setup step 6, "Schedule" (mockup step 6, UI design §4): how often (hourly by default), the battery rule,
/// retention (shown and editable) and the optional check-in URL with why it matters (product spec §6.2).
/// The hotspot rule is Mac-wide (Settings → Network) and the upload limit is in Settings only, so neither is
/// here. Continue saves the plan; it still doesn't run until Done.
struct ScheduleView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.schedule != nil {
                ScheduleFields(model: model)
            } else {
                ProgressView().controlSize(.small)
            }
            SetupStepStatus(model: model)
            Spacer(minLength: 12)
            SetupButtonRow {
                if model.working { ProgressView().controlSize(.small) }
                Button("Continue") { Task { await model.continueFromSchedule() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.schedule == nil || model.scheduleProblem != nil)
            }
        }
        .task {
            await model.loadPlan()
            model.prepareSchedule()
        }
    }
}

private struct ScheduleFields: View {
    @Bindable var model: SetupModel

    var body: some View {
        let form = Binding(get: { model.schedule! }, set: { model.schedule = $0 })
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Back up")
                IntervalPicker(hours: form.intervalHours)
            }
            GridRow {
                Text("On battery")
                BatteryPicker(rule: form.battery)
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Keep")
                RetentionFields(form: form)
            }
        }
        .disabled(model.working)
        Divider()
        CheckInField(model: model)
    }
}

/// The check-in URL is a secret: typed into a `SecretField`, held in the draft until Continue saves it.
private struct CheckInField: View {
    @Bindable var model: SetupModel

    var body: some View {
        let key = SecretKey.checkInURL(model.planID)
        CheckInURLField(
            saved: model.plan?.hasCheckInURL == true, remove: $model.removeCheckInURL,
            text: Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) }),
            problem: model.checkInProblem)
            .disabled(model.working)
        // The kit step came before this one, so the kit saved there has no check-in URL.
        Text("The recovery kit you saved doesn’t include this URL, which isn’t needed to restore. Once it’s saved, Show Recovery Kit… on the plan’s Storage tab includes it.")
            .explanatoryNote()
    }
}
