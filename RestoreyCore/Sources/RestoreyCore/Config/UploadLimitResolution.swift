import Foundation

/// An upload speed measured on one network (`networkQuality` upload capacity), kept so a percentage limit can be
/// worked out without a test at every backup. Defined here so the resolution below and the measurement store
/// share one type.
public struct UploadSpeedMeasurement: Codable, Sendable, Equatable {
    public var bitsPerSecond: Double
    /// Bytes the test sent, when it reports them.
    public var bytesSent: Int64?
    /// UTC.
    public var measuredAt: Date

    public init(bitsPerSecond: Double, bytesSent: Int64? = nil, measuredAt: Date) {
        self.bitsPerSecond = bitsPerSecond
        self.bytesSent = bytesSent
        self.measuredAt = measuredAt
    }
}

extension LimitWindow {
    /// Whether `date` falls inside the window. A window that crosses midnight belongs to the day it starts on
    /// (weekdays 22:00 to 06:00 includes Saturday 05:00). Weekdays means Monday to Friday whatever the
    /// calendar's first weekday is.
    ///
    /// Boundaries are wall-clock times in `calendar`'s time zone. A boundary that does not exist on a
    /// daylight-saving-start day (02:30 when clocks go from 2:00 to 3:00) is the calendar's next valid time (03:00); a
    /// repeated hour at daylight-saving end uses its first occurrence.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: date)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
        return [yesterday, today].contains { day in
            guard let interval = interval(startingOn: day, calendar: calendar) else { return false }
            return interval.start <= date && date < interval.end
        }
    }

    /// The next instant after `date` at which `contains` changes value. Nil only if it never changes.
    public func nextChange(after date: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: date)
        var best: Date?
        // The day before covers an interval that crossed midnight into today; 8 days ahead covers a gap of
        // a weekend or a weekday window's longest wait.
        for offset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let interval = interval(startingOn: day, calendar: calendar) else { continue }
            for boundary in [interval.start, interval.end] where boundary > date {
                if best == nil || boundary < best! { best = boundary }
            }
        }
        return best
    }

    /// The interval that starts on `day`'s calendar day, nil when `days` doesn't allow that day.
    private func interval(startingOn day: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let weekday = calendar.component(.weekday, from: day)  // 1 = Sunday ... 7 = Saturday
        let isWeekend = weekday == 1 || weekday == 7
        switch days {
        case .everyDay: break
        case .weekdays: if isWeekend { return nil }
        case .weekends: if !isWeekend { return nil }
        }
        let crossesMidnight = endMinute < startMinute
        guard let start = wallClock(minute: startMinute, on: day, calendar: calendar),
              let endDay = crossesMidnight ? calendar.date(byAdding: .day, value: 1, to: day) : day,
              let end = wallClock(minute: endMinute, on: endDay, calendar: calendar) else { return nil }
        return (start, end)
    }

    private func wallClock(minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0,
            of: calendar.startOfDay(for: day), matchingPolicy: .nextTime)
    }
}

/// What the Mac-wide limit is for a backup that starts at a given moment, and why.
public struct ResolvedMacWideLimit: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case noLimitSet
        case outsideWindow
        case rate
        case percentOf(UploadSpeedMeasurement)
        case percentNotMeasured
    }

    /// The Mac-wide limit in KiB/s, nil for no limit.
    public var kiB: Int?
    public var reason: Reason
    /// When a backup starting later would get a different answer because of the window. Nil without a window.
    public var changesAt: Date?
}

/// Resolves the Mac-wide limit at `date`: outside the window there is none; a rate is that rate; a percentage
/// is that share of `measurement` (the current network's latest), in KiB/s rounded down and never below 1, or
/// no limit when there is no measurement.
public func resolveMacWideLimit(
    _ settings: NetworkSettings, measurement: UploadSpeedMeasurement?, at date: Date, calendar: Calendar
) -> ResolvedMacWideLimit {
    let window = settings.limitWindow
    let changesAt = window?.nextChange(after: date, calendar: calendar)
    func result(_ kiB: Int?, _ reason: ResolvedMacWideLimit.Reason) -> ResolvedMacWideLimit {
        ResolvedMacWideLimit(kiB: kiB, reason: reason, changesAt: changesAt)
    }

    // No limit never changes with the time, so a window left in the config doesn't matter.
    if case .none = settings.uploadLimit { return ResolvedMacWideLimit(kiB: nil, reason: .noLimitSet, changesAt: nil) }
    if let window, !window.contains(date, calendar: calendar) { return result(nil, .outsideWindow) }
    switch settings.uploadLimit {
    case .none:
        return ResolvedMacWideLimit(kiB: nil, reason: .noLimitSet, changesAt: nil)
    case .rate(let kiB, _):
        return result(kiB, .rate)
    case .percent(let percent):
        // The measurement comes from a file and parsed tool output: a value that isn't a positive finite
        // number counts as not measured.
        guard let measurement, measurement.bitsPerSecond.isFinite, measurement.bitsPerSecond > 0 else {
            return result(nil, .percentNotMeasured)
        }
        let share = (measurement.bitsPerSecond / 8 / 1024 * Double(percent) / 100).rounded(.down)
        let kiB = Int(min(share, Double(Int32.max)))
        return result(max(1, kiB), .percentOf(measurement))
    }
}
