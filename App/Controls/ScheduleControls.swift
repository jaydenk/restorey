import RestoreyCore
import SwiftUI

// The schedule, retention and check-in controls setup's Schedule step and Settings' Schedule and Retention tabs
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

/// Retention: the four counts as text, with the form's sentence when one doesn't read. Setup's step, which is narrow;
/// Settings lays the counts out as rows, each with a stepper (`RetentionCountField`).
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
                SeverityText(problem.message)
            }
        }
    }
}

private struct CountField: View {
    @Binding var text: String
    let unit: String

    var body: some View {
        HStack(spacing: 3) {
            PlainTextField(title: unit, text: $text, isNumeric: true).frame(width: 46)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

/// A number's field with its stepper and unit (HIG Steppers: a stepper sits beside the field that shows its value, and
/// a field lets people type a value far from the current one). The field keeps exactly what is typed and is checked
/// as before; a click writes the next value (`StepperText`). Task 17c, P14.
struct NumberField: View {
    /// What VoiceOver calls the field and its stepper.
    let name: String
    /// The empty field's placeholder.
    let placeholder: String
    @Binding var text: String
    var unit: String?
    var width: CGFloat = 52
    /// The text one step up (+1) or down (−1) from the text given.
    let step: (String, Int) -> String

    var body: some View {
        HStack(spacing: 4) {
            PlainTextField(title: placeholder, text: $text, isNumeric: true, accessibilityName: name)
                .frame(width: width)
            Stepper(name, onIncrement: { text = step(text, 1) }, onDecrement: { text = step(text, -1) })
                .labelsHidden()
                .accessibilityLabel(name)
            if let unit { Text(unit).foregroundStyle(.secondary) }
        }
    }
}

/// One retention count in Settings → Plans → Retention, with its stepper.
struct RetentionCountField: View {
    let name: String
    @Binding var text: String

    var body: some View {
        NumberField(name: name, placeholder: "0", text: $text, step: StepperText.count)
    }
}

/// A plan's upload limit, empty for none ("None"), with its stepper and a KB/s / MB/s picker. Choosing the other unit
/// converts the amount, so 5 MB/s becomes 5120 KB/s (`PlanEditModel.uploadLimitUnit`).
struct UploadLimitField: View {
    let name: String
    @Binding var text: String
    @Binding var unit: UploadLimitUnit

    var body: some View {
        HStack(spacing: 6) {
            NumberField(name: name, placeholder: "None", text: $text, width: 70) { StepperText.uploadLimit($0, by: $1, unit: unit) }
            Picker("Unit of \(name)", selection: $unit) {
                ForEach(UploadLimitUnit.allCases, id: \.self) { Text(FormValidation.unitName($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The Mac-wide limit's amount and kind: a number (a rate or a percentage) with its stepper, and the picker of None,
/// KB/s, MB/s and % of upload speed. Changing the kind goes through `onKind`, which converts the amount and, for a
/// percentage, asks for Location permission (`NetworkEditModel.setLimitKind`).
struct MacLimitField: View {
    let name: String
    @Binding var amount: String
    let kind: LimitKind
    let onKind: (LimitKind) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if kind != .none {
                NumberField(name: name, placeholder: kind == .percent ? "50" : "Amount", text: $amount, width: 70) { text, by in
                    kind == .percent ? StepperText.percent(text, by: by) : StepperText.uploadLimit(text, by: by, unit: kind.unit ?? .megabytes)
                }
            }
            Picker("Kind of \(name)", selection: Binding(get: { kind }, set: onKind)) {
                ForEach(LimitKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// A time of day to the minute, as the Mac shows times (12 or 24 hour). The value is minutes after midnight; the
/// picker works in UTC on a fixed day, so a daylight-saving change can't move it.
struct TimeOfDayPicker: View {
    let name: String
    @Binding var minute: Int

    var body: some View {
        DatePicker(name, selection: Binding(get: { Self.date(minute) }, set: { minute = Self.minute($0) }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .environment(\.timeZone, .gmt)
            .accessibilityLabel(name)
    }

    private static func date(_ minute: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }

    private static func minute(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

/// The days a limit window applies on.
struct LimitDaysPicker: View {
    @Binding var days: LimitDays

    var body: some View {
        Picker("Days", selection: $days) {
            Text("Every day").tag(LimitDays.everyDay)
            Text("Weekdays").tag(LimitDays.weekdays)
            Text("Weekends").tag(LimitDays.weekends)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The optional check-in URL, a secret: "A check-in URL is saved" with Remove when there is one, otherwise a
/// `SecretField`; then why it is worth having (product spec §6.2). Setup's Schedule step lays it out as a labelled
/// field; Settings → Plans → Schedule puts `CheckInURLValue` in a form row and the explanation in the section's footer.
struct CheckInURLField: View {
    /// The plan has one saved (`Plan.hasCheckInURL`).
    let saved: Bool
    @Binding var remove: Bool
    @Binding var text: String
    let problem: String?

    var body: some View {
        SetupField(label: CheckInURLValue.label, problem: problem) {
            CheckInURLValue(saved: saved, remove: $remove, text: $text)
        }
        Text(ScheduleForm.checkInExplanation)
            .explanatoryNote()
    }
}

/// The check-in URL's control: "A check-in URL is saved." with Remove while one is saved and kept, otherwise the secret's
/// field. Shared by setup and Settings, so the two can't drift apart.
struct CheckInURLValue: View {
    static let label = "Check-in URL (optional)"

    let saved: Bool
    @Binding var remove: Bool
    @Binding var text: String

    /// Whether the field shows (rather than the saved note), for a row that sizes the field.
    static func showsField(saved: Bool, remove: Bool) -> Bool { !saved || remove }

    var body: some View {
        if Self.showsField(saved: saved, remove: remove) {
            SecretField(title: "https://hc-ping.com/…", text: $text)
        } else {
            HStack {
                Text("A check-in URL is saved.")
                Button("Remove") { remove = true }
            }
            .fixedSize()
        }
    }
}
