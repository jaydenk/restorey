import Foundation
import Testing
@testable import RestoreyCore

struct DisplayFormatTests {
    private static let locale = Locale(identifier: "en_AU")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        calendar.locale = locale
        return calendar
    }()

    @Test func sizes() {
        #expect(DisplayFormat.size(486_000_000_000, locale: Self.locale) == "486 GB")
        #expect(DisplayFormat.size(1_200_000_000, locale: Self.locale) == "1.2 GB")
        #expect(DisplayFormat.size(2_000_000_000, locale: Self.locale) == "2 GB")
        #expect(DisplayFormat.size(18_000_000, locale: Self.locale) == "18 MB")
        #expect(DisplayFormat.size(512_000, locale: Self.locale) == "512 kB")
        #expect(DisplayFormat.size(0, locale: Self.locale) == "0 B")
        #expect(DisplayFormat.size(2_500_000_000_000, locale: Self.locale) == "2.5 TB")
    }

    @Test func theUnitIsChosenAfterRounding() {
        #expect(DisplayFormat.size(999_999, locale: Self.locale) == "1 MB")
        #expect(DisplayFormat.size(999_999_999, locale: Self.locale) == "1 GB")
        #expect(DisplayFormat.size(999_960_000_000, locale: Self.locale) == "1 TB")
        #expect(DisplayFormat.size(999_400, locale: Self.locale) == "999 kB")
        #expect(DisplayFormat.size(999, locale: Self.locale) == "999 B")
        #expect(DisplayFormat.progress(done: 1, of: 999_999, locale: Self.locale) == "0 of 1 MB")
    }

    @Test func progressSharesTheTotalsUnit() {
        #expect(DisplayFormat.progress(done: 1_200_000_000, of: 2_900_000_000, locale: Self.locale) == "1.2 of 2.9 GB")
        #expect(DisplayFormat.progress(done: 400_000, of: 2_900_000_000, locale: Self.locale) == "0 of 2.9 GB")
        #expect(DisplayFormat.progress(done: 40_000_000, of: 90_000_000, locale: Self.locale) == "40 of 90 MB")
    }

    @Test func remainingTimes() {
        #expect(DisplayFormat.remaining(seconds: 360) == "~6 min")
        #expect(DisplayFormat.remaining(seconds: 20) == "~1 min")
        #expect(DisplayFormat.remaining(seconds: 3_600) == "~1 h")
        #expect(DisplayFormat.remaining(seconds: 7_500) == "~2 h 5 min")
    }

    /// A run's length in the history: seconds under a minute, then minutes, then hours and minutes.
    @Test func durations() {
        #expect(DisplayFormat.duration(seconds: 0) == "0 s")
        #expect(DisplayFormat.duration(seconds: 7.4) == "7 s")
        #expect(DisplayFormat.duration(seconds: 59.6) == "1 min")
        #expect(DisplayFormat.duration(seconds: 125) == "2 min")
        #expect(DisplayFormat.duration(seconds: 3600) == "1 h")
        #expect(DisplayFormat.duration(seconds: 3900) == "1 h 5 min")
        #expect(DisplayFormat.duration(seconds: -3) == "0 s")
    }

    @Test func clockTimeIsTwentyFourHourInTheCalendarsZone() {
        // 04:16 UTC is 14:16 in Brisbane.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 4, minute: 16))!
        #expect(DisplayFormat.time(date, calendar: Self.calendar, locale: Self.locale) == "14:16")
    }

    @Test func relativeAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DisplayFormat.age(of: now.addingTimeInterval(-3 * 86_400), now: now, calendar: Self.calendar, locale: Self.locale) == "3 days ago")
        #expect(DisplayFormat.age(of: now.addingTimeInterval(-86_400), now: now, calendar: Self.calendar, locale: Self.locale) == "1 day ago")
        #expect(DisplayFormat.age(of: now.addingTimeInterval(-5 * 3_600), now: now, calendar: Self.calendar, locale: Self.locale) == "5 hours ago")
        #expect(DisplayFormat.age(of: now.addingTimeInterval(-10), now: now, calendar: Self.calendar, locale: Self.locale) == "just now")
    }
}
