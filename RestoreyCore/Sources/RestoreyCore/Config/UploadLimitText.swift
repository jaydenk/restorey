import Foundation

/// How the Mac-wide upload limit is told in words, from one place: the agent's log line about how a limit was
/// resolved and Settings → Network's "Now" and speed lines use these, so the two can't word it differently.
///
/// Times and dates follow `locale`: the app passes the Mac's, and the agent's log pins `en_AU` so a log reads the
/// same on every Mac.
public enum UploadLimitText {
    /// "500 KB/s", "4.77 MB/s": a limit in the unit the person chose to read it in.
    public static func rateText(kiB: Int, unit: UploadLimitUnit) -> String {
        switch unit {
        case .kilobytes: "\(kiB) KB/s"
        case .megabytes: "\(FormValidation.uploadLimitText(kiB: kiB, unit: .megabytes)) MB/s"
        }
    }

    /// A speed or a resolved limit: MB/s with up to one decimal, or KB/s below 1 MB/s ("40 MB/s", "4.8 MB/s",
    /// "300 KB/s").
    public static func speedText(kiB: Int) -> String {
        guard kiB >= 1024 else { return "\(kiB) KB/s" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        let megabytes = formatter.string(from: NSNumber(value: Double(kiB) / 1024)) ?? "\(kiB / 1024)"
        return "\(megabytes) MB/s"
    }

    /// "8:00 am–6:00 pm weekdays".
    public static func windowText(_ window: LimitWindow, locale: Locale) -> String {
        let days = switch window.days {
        case .everyDay: "every day"
        case .weekdays: "weekdays"
        case .weekends: "weekends"
        }
        return "\(timeText(minute: window.startMinute, locale: locale))–\(timeText(minute: window.endMinute, locale: locale)) \(days)"
    }

    /// A time of day given as minutes after midnight: "8:00 am".
    public static func timeText(minute: Int, locale: Locale) -> String {
        // A fixed instant in UTC: only its hour and minute are shown, so the zone and day don't matter.
        format(Date(timeIntervalSince1970: TimeInterval(minute * 60)), template: "jmm", locale: locale, timeZone: .gmt)
    }

    /// The time of `date` on `calendar`'s clock: "6:00 pm".
    public static func timeText(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        format(date, template: "jmm", locale: locale, timeZone: calendar.timeZone)
    }

    /// The day of the week `date` falls on, on `calendar`'s clock: "Monday".
    public static func weekdayText(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        format(date, template: "EEEE", locale: locale, timeZone: calendar.timeZone)
    }

    /// "today", "yesterday", or the date ("14 Jan 2027").
    public static func dayText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return format(date, template: "dMMMyyyy", locale: locale, timeZone: calendar.timeZone)
    }

    private static func format(_ date: Date, template: String, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        // ICU puts a narrow no-break space before "am" and "pm"; a plain space reads (and is typed) the same.
        return formatter.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
