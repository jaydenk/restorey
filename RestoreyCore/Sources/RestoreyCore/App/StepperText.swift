import Foundation

/// What a number field's stepper writes into the field (Task 17c, HIG Steppers: "pair a stepper with a text field").
/// The fields keep exactly what is typed and their checks are unchanged (`ScheduleForm.countProblem`,
/// `FormValidation.uploadLimit`); a click only replaces the text with the next value. Text that doesn't read as a
/// number steps from 0, so the stepper is never dead.
public enum StepperText {
    /// A retention count (0 to 9999, as `ScheduleForm.countProblem` allows), one step `by` up or down, kept in range.
    public static func count(_ text: String, by step: Int) -> String {
        let current = Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        return String(min(max(current + step, countRange.lowerBound), countRange.upperBound))
    }

    public static let countRange = 0...9999

    /// An upload limit in MB/s, one whole MB/s `by` up or down. Empty is no limit: up from it is 1, and down to 0 or
    /// below is empty again (a limit must be more than 0, `FormValidation.uploadLimit`). A fraction keeps its
    /// fraction ("1.5" up is "2.5"), written with a full stop whatever the Mac's region, as the field shows limits.
    public static func uploadLimit(_ text: String, by step: Int) -> String {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let posix = Locale(identifier: "en_US_POSIX")
        let current = typed.isEmpty ? 0 : Decimal(string: typed, locale: posix) ?? 0
        let next = current + Decimal(step)
        guard next > 0 else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = posix
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: next as NSDecimalNumber) ?? "\(next)"
    }
}
