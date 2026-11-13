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
                Picker("Back up", selection: form.intervalHours) {
                    ForEach(ScheduleForm.intervalHours, id: \.self) { Text(ScheduleForm.title(hours: $0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("On battery")
                Picker("On battery", selection: form.battery) {
                    ForEach(ScheduleForm.batteryChoices, id: \.self) { Text(ScheduleForm.title(battery: $0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Keep")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        CountField(text: form.hourly, unit: "hourly")
                        CountField(text: form.daily, unit: "daily")
                        CountField(text: form.weekly, unit: "weekly")
                        CountField(text: form.monthly, unit: "monthly")
                    }
                    if case .failure(let problem) = model.schedule!.retention {
                        Text(problem.message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .disabled(model.working)
        Divider()
        CheckInField(model: model)
    }
}

private struct CountField: View {
    @Binding var text: String
    let unit: String

    var body: some View {
        HStack(spacing: 3) {
            PlainTextField(title: unit, text: $text).frame(width: 46)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

/// The check-in URL is a secret: typed into a `SecretField`, held in the draft until Continue saves it.
private struct CheckInField: View {
    @Bindable var model: SetupModel

    var body: some View {
        let key = SecretKey.checkInURL(model.planID)
        SetupField(label: "Check-in URL (optional)", problem: model.checkInProblem) {
            if model.plan?.hasCheckInURL == true, !model.removeCheckInURL {
                HStack {
                    Text("A check-in URL is saved.")
                    Button("Remove") { model.removeCheckInURL = true }
                }
            } else {
                SecretField(
                    title: "https://hc-ping.com/…",
                    text: Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) }))
            }
        }
        .disabled(model.working)
        Text(ScheduleForm.checkInExplanation)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
