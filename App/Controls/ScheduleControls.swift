import RestoreyCore
import SwiftUI

// The schedule, retention and check-in controls setup's Schedule step and Settings' Schedule, Keep and Alerts tabs
// share. Each binds straight to the stored value (`ScheduleForm`'s text, the secret as typed): parsing and
// checking are `ScheduleForm`'s and the caller's.

/// How often: hourly to once a day (`ScheduleForm.intervalHours`).
struct IntervalPicker: View {
    @Binding var hours: Int

    var body: some View {
        Picker("Back up", selection: $hours) {
            ForEach(ScheduleForm.intervalHours, id: \.self) { Text(ScheduleForm.title(hours: $0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The battery rule: a minimum charge, always or never (`ScheduleForm.batteryChoices`).
struct BatteryPicker: View {
    @Binding var rule: BatteryRule

    var body: some View {
        Picker("On battery", selection: $rule) {
            ForEach(ScheduleForm.batteryChoices, id: \.self) { Text(ScheduleForm.title(battery: $0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Retention: the four counts as text, with the form's sentence when one doesn't read.
struct RetentionFields: View {
    @Binding var form: ScheduleForm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CountField(text: $form.hourly, unit: "hourly")
                CountField(text: $form.daily, unit: "daily")
                CountField(text: $form.weekly, unit: "weekly")
                CountField(text: $form.monthly, unit: "monthly")
            }
            if case .failure(let problem) = form.retention {
                Text(problem.message).font(.caption).foregroundStyle(.red)
            }
        }
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

/// The optional check-in URL, a secret: "A check-in URL is saved" with Remove when there is one, otherwise a
/// `SecretField`; then why it is worth having (product spec §6.2).
struct CheckInURLField: View {
    /// The plan has one saved (`Plan.hasCheckInURL`).
    let saved: Bool
    @Binding var remove: Bool
    @Binding var text: String
    let problem: String?

    var body: some View {
        SetupField(label: "Check-in URL (optional)", problem: problem) {
            if saved, !remove {
                HStack {
                    Text("A check-in URL is saved.")
                    Button("Remove") { remove = true }
                }
            } else {
                SecretField(title: "https://hc-ping.com/…", text: $text)
            }
        }
        Text(ScheduleForm.checkInExplanation)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
