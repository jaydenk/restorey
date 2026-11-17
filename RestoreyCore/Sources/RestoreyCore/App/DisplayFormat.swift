import Foundation

/// Text for the menu: sizes, times and ages, in the person's locale. Sizes are decimal (1 GB is a
/// billion bytes), as restic and Backblaze count them.
public enum DisplayFormat {
    private static let units: [(name: String, size: Double)] = [
        ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3),
    ]

    /// The unit to show `value` in, chosen after rounding so 999.96 GB reads "1 TB", not "1000 GB". Nil means bytes.
    private static func unit(for value: Double) -> (name: String, size: Double)? {
        guard let index = units.firstIndex(where: { value >= $0.size }) else {
            return value.rounded() >= 1000 ? units.last : nil
        }
        if index > 0, rounded(value / units[index].size) >= 1000 { return units[index - 1] }
        return units[index]
    }

    /// Rounded as `number` rounds: to a whole number from 10 up, otherwise one decimal.
    private static func rounded(_ value: Double) -> Double {
        value >= 10 ? value.rounded(.toNearestOrAwayFromZero) : (value * 10).rounded(.toNearestOrAwayFromZero) / 10
    }

    /// "486 GB", "1.2 GB", "18 MB", "0 B".
    public static func size(_ bytes: Int64, locale: Locale) -> String {
        let value = Double(max(bytes, 0))
        guard let unit = unit(for: value) else { return "\(number(value, locale: locale)) B" }
        return "\(number(value / unit.size, locale: locale)) \(unit.name)"
    }

    /// "1.2 of 2.9 GB": both numbers in the total's unit.
    public static func progress(done: Int, of total: Int, locale: Locale) -> String {
        let total = Double(max(total, 0))
        guard let unit = unit(for: total) else {
            return "\(number(Double(max(done, 0)), locale: locale)) of \(number(total, locale: locale)) B"
        }
        let doneText = number(Double(max(done, 0)) / unit.size, locale: locale)
        return "\(doneText) of \(number(total / unit.size, locale: locale)) \(unit.name)"
    }

    /// "Checking for changes… 412,000 files so far": what a backup says while restic is still counting what there is
    /// to back up (Task 16e). `filesDone` is the files restic has looked at; none yet, no count.
    public static func checkingForChanges(filesDone: Int, locale: Locale) -> String {
        guard filesDone > 0 else { return "Checking for changes…" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: filesDone)) ?? "\(filesDone)"
        return "Checking for changes… \(count) \(filesDone == 1 ? "file" : "files") so far"
    }

    /// "~6 min", "~2 h 5 min". Never under a minute: a shorter wait is "~1 min".
    public static func remaining(seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        guard minutes >= 60 else { return "~\(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "~\(hours) h" : "~\(hours) h \(rest) min"
    }

    /// How long a run took: "7 s" under a minute, then "2 min", "1 h", "1 h 5 min" (rounded to the nearest).
    public static func duration(seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0).rounded())
        guard whole >= 60 else { return "\(whole) s" }
        let minutes = Int((Double(whole) / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The time of day as the locale writes a 24-hour clock ("14:16"), in the calendar's time zone.
    public static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        formatter(template: "Hmm", calendar: calendar, locale: locale).string(from: date)
    }

    /// "9 Nov", in the calendar's time zone.
    public static func dayAndMonth(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        formatter(template: "dMMM", calendar: calendar, locale: locale).string(from: date)
    }

    /// "3 days ago", "5 hours ago", "just now" within the last minute.
    public static func age(of date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// One decimal below 10, none from 10 up; a trailing ".0" is dropped.
    private static func number(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value >= 10 ? 0 : 1
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatter(template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
