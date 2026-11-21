import Foundation
import Testing
@testable import RestoreyCore

struct UploadLimitResolutionTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Adelaide")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // November 2026: Mon 16, Fri 20, Sat 21, Sun 22, Mon 23.
    private func nov(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date { at(2026, 11, d, h, mi) }

    private let workHours = LimitWindow(days: .weekdays, startMinute: 8 * 60, endMinute: 18 * 60)

    @Test func weekdayWindowContainsWeekdayHoursOnly() {
        #expect(!workHours.contains(nov(16, 7, 59), calendar: calendar))
        #expect(workHours.contains(nov(16, 8), calendar: calendar))
        #expect(workHours.contains(nov(16, 17, 59), calendar: calendar))
        #expect(!workHours.contains(nov(16, 18), calendar: calendar))
        #expect(!workHours.contains(nov(21, 12), calendar: calendar))
    }

    @Test func midnightWindowBelongsToTheDayItStarts() {
        let night = LimitWindow(days: .weekdays, startMinute: 22 * 60, endMinute: 6 * 60)
        #expect(night.contains(nov(20, 23), calendar: calendar))   // Fri 23:00
        #expect(night.contains(nov(21, 5), calendar: calendar))    // Sat 05:00, started Fri
        #expect(!night.contains(nov(21, 23), calendar: calendar))  // Sat 23:00
        #expect(!night.contains(nov(23, 5), calendar: calendar))   // Mon 05:00, Sunday doesn't start one
        #expect(night.contains(nov(23, 23), calendar: calendar))   // Mon 23:00
    }

    @Test func windowAcrossDaylightSavingStartUsesWallClock() {
        // 4 Oct 2026: Adelaide clocks go from 2:00 to 3:00.
        let window = LimitWindow(days: .everyDay, startMinute: 60, endMinute: 4 * 60)
        #expect(window.contains(at(2026, 10, 4, 1, 30), calendar: calendar))
        #expect(window.contains(at(2026, 10, 4, 3, 30), calendar: calendar))
        #expect(!window.contains(at(2026, 10, 4, 4, 30), calendar: calendar))
    }

    @Test func aBoundaryInTheSkippedHourUsesTheNextValidTime() {
        // 02:30 does not exist on 4 Oct 2026; the calendar's next valid time is 03:00, when the clocks resume.
        let window = LimitWindow(days: .everyDay, startMinute: 2 * 60 + 30, endMinute: 5 * 60)
        #expect(!window.contains(at(2026, 10, 4, 1, 59), calendar: calendar))
        #expect(window.contains(at(2026, 10, 4, 3, 0), calendar: calendar))
    }

    @Test func nextChangeIsTheNextBoundary() {
        #expect(workHours.nextChange(after: nov(16, 12), calendar: calendar) == nov(16, 18))
        #expect(workHours.nextChange(after: nov(20, 19), calendar: calendar) == nov(23, 8))
        // Exactly on a boundary, the change is the one after it.
        #expect(workHours.nextChange(after: nov(16, 8), calendar: calendar) == nov(16, 18))
    }

    private func settings(_ limit: MacUploadLimit, window: LimitWindow? = nil) -> NetworkSettings {
        NetworkSettings(uploadLimit: limit, limitWindow: window, skipOnConstrainedNetwork: true, skippedWiFiNames: [])
    }

    private func measurement(_ bitsPerSecond: Double) -> UploadSpeedMeasurement {
        UploadSpeedMeasurement(bitsPerSecond: bitsPerSecond, bytesSent: nil, measuredAt: nov(21, 9))
    }

    @Test func percentOfMeasuredSpeed() {
        let fast = measurement(320_000_000)
        let half = resolveMacWideLimit(settings(.percent(50)), measurement: fast, at: nov(21, 12), calendar: calendar)
        #expect(half.kiB == 19_531)
        #expect(half.reason == .percentOf(fast))
        let slow = measurement(8_000)
        let tiny = resolveMacWideLimit(settings(.percent(1)), measurement: slow, at: nov(21, 12), calendar: calendar)
        #expect(tiny.kiB == 1)
    }

    @Test func percentWithoutMeasurementIsNoLimit() {
        let r = resolveMacWideLimit(settings(.percent(50)), measurement: nil, at: nov(21, 12), calendar: calendar)
        #expect(r.kiB == nil)
        #expect(r.reason == .percentNotMeasured)
    }

    @Test func outsideWindowIsNoLimitEvenForARate() {
        let r = resolveMacWideLimit(
            settings(.rate(kiB: 500, unit: .kilobytes), window: workHours),
            measurement: nil, at: nov(21, 12), calendar: calendar)
        #expect(r.kiB == nil)
        #expect(r.reason == .outsideWindow)
        #expect(r.changesAt == nov(23, 8))
    }

    @Test func insideWindowRateAppliesAndSaysWhenItEnds() {
        let r = resolveMacWideLimit(
            settings(.rate(kiB: 500, unit: .kilobytes), window: workHours),
            measurement: nil, at: nov(16, 12), calendar: calendar)
        #expect(r.kiB == 500)
        #expect(r.reason == .rate)
        #expect(r.changesAt == nov(16, 18))
    }

    @Test func noLimitSetIsNoLimit() {
        let r = resolveMacWideLimit(settings(.none, window: workHours), measurement: nil, at: nov(16, 12), calendar: calendar)
        #expect(r.kiB == nil)
        #expect(r.reason == .noLimitSet)
    }

    @Test func rateWithoutWindowNeverChanges() {
        let r = resolveMacWideLimit(
            settings(.rate(kiB: 500, unit: .kilobytes)), measurement: nil, at: nov(21, 12), calendar: calendar)
        #expect(r.kiB == 500)
        #expect(r.changesAt == nil)
    }

    @Test func noLimitWithAStoredWindowIsNoLimitSetOutsideItToo() {
        let r = resolveMacWideLimit(settings(.none, window: workHours), measurement: nil, at: nov(21, 12), calendar: calendar)
        #expect(r.kiB == nil)
        #expect(r.reason == .noLimitSet)
        #expect(r.changesAt == nil)
    }

    @Test func anUnusableMeasurementIsNotMeasuredAndNeverTraps() {
        for bits in [Double.nan, .infinity, -.infinity, 0, -5] {
            let r = resolveMacWideLimit(settings(.percent(50)), measurement: measurement(bits), at: nov(21, 12), calendar: calendar)
            #expect(r.kiB == nil)
            #expect(r.reason == .percentNotMeasured)
        }
    }

    @Test func aHugeMeasurementIsClampedRatherThanTrapping() {
        let huge = measurement(1e30)
        let r = resolveMacWideLimit(settings(.percent(100)), measurement: huge, at: nov(21, 12), calendar: calendar)
        #expect(r.kiB == Int(Int32.max))
        #expect(r.reason == .percentOf(huge))
    }
}
