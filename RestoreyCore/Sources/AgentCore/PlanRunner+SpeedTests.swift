import Foundation
import RestoreyCore

/// The upload speed tests and the Mac-wide limit resolved at a backup's start (the upload-limit design).
///
/// **A test never overlaps a networked restic command.** Every test the agent starts goes through `runSpeedTest`,
/// which checks `networkedCommands` and counts itself in `speedTestsAsked` in one step on this actor, before it
/// suspends. A networked command, just before restic starts, waits in `waitForSpeedTests` until the tester is idle
/// and no test asked for here is on its way to it, then registers in `networkedCommands` with no suspension in between.
/// So whichever comes first on this actor wins: a test asked for after a command registered is refused, and a
/// command that comes after a test was asked for waits for it.
///
/// **No deadlock.** A command waits for tests; a test never waits for a command (it is refused instead), and a test
/// always ends (`NetworkQuality.run` is bounded). The test before a backup runs before that backup registers, so a
/// second backup arriving during it isn't held up by the first: it joins the same test (the tester's per-network task),
/// and both then wait only for that test.
extension PlanRunner {
    // MARK: Tests

    /// Runs a test of `key`'s upload speed, or joins the one in flight. Nil, without testing, when restic is running a
    /// networked command or there is no tester. The caller has checked the network (`SpeedTestRefusal.check`).
    func runSpeedTest(_ key: NetworkKey) async -> Result<UploadSpeedMeasurement, SpeedTestError>? {
        guard let tester = deps.speedTester, networkedCommands.isEmpty else { return nil }
        speedTestsAsked += 1
        let result = await tester.test(key)
        speedTestsAsked -= 1
        if speedTestsAsked == 0 {
            let waiters = speedTestWaiters
            speedTestWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        return result
    }

    /// Returns once no upload speed test is running or on its way to the tester. The caller registers its command in
    /// `networkedCommands` straight after, with no suspension, so no test can start in between.
    func waitForSpeedTests() async {
        guard let tester = deps.speedTester else { return }
        while true {
            await tester.waitUntilIdle()
            if speedTestsAsked == 0 { return }
            await withCheckedContinuation { speedTestWaiters.append($0) }
        }
    }

    /// The day's test (the upload-limit design, "When it runs"), checked on every scheduler tick: when the Mac-wide
    /// limit is a percentage, the network may be tested, no networked restic command is running, and the current
    /// network hasn't been tested (successfully or not) today. Returns the started test without waiting for it; nil
    /// when none is due.
    @discardableResult
    func beginDailySpeedTestIfDue() async -> Task<Void, Never>? {
        guard let tester = deps.speedTester else { return nil }
        let settings = await deps.state.networkSettings
        guard case .percent = settings.uploadLimit, networkedCommands.isEmpty else { return nil }
        let network = await currentNetwork(settings)
        guard let key = network.key,
            SpeedTestRefusal.check(
                network: network.state, settings: settings, wiFiName: network.wiFiName, networkedCommandRunning: false) == nil,
            !(await tester.testedToday(key, calendar: .current))
        else { return nil }
        // `runSpeedTest` checks for a networked command again: one may have started while this looked.
        return Task { _ = await runSpeedTest(key) }
    }

    /// The network the Mac is on now and its key. The Wi-Fi name is read only on Wi-Fi with a percentage set, the one
    /// case it's needed for (a percentage's measurement belongs to the network); CoreWLAN never prompts for Location,
    /// it answers nil without it.
    func currentNetwork(_ settings: NetworkSettings) async -> (state: NetworkState, key: NetworkKey?, wiFiName: String?) {
        let environment = await deps.preflightEnvironment()
        var wiFiName: String?
        if case .satisfied(_, _, .wiFi) = environment.network, case .percent = settings.uploadLimit {
            wiFiName = environment.currentWiFiName()
        }
        return (environment.network, networkKey(for: environment.network, wiFiName: wiFiName), wiFiName)
    }

    // MARK: Resolving the limit at a backup's start

    /// The Mac-wide limit for a backup to a networked repository starting now, and the run log's line saying how it was
    /// resolved. With a percentage set, on a network with no measurement, inside the window (or with none), and on a
    /// network that may be tested, the test runs first; if it fails, or can't run because another networked command
    /// is running, there is no Mac-wide limit. Called before the backup registers in `networkedCommands`.
    func resolveMacWideLimitKiB() async -> (kiB: Int?, logLine: String) {
        let settings = await deps.state.networkSettings
        var key: NetworkKey?
        var measurement: UploadSpeedMeasurement?
        if case .percent = settings.uploadLimit, let tester = deps.speedTester {
            let network = await currentNetwork(settings)
            key = network.key
            if let key {
                measurement = await tester.record(for: key)?.latest
                let insideWindow = settings.limitWindow?.contains(deps.now(), calendar: .current) ?? true
                if measurement == nil, insideWindow,
                    SpeedTestRefusal.check(
                        network: network.state, settings: settings, wiFiName: network.wiFiName,
                        networkedCommandRunning: false) == nil,
                    case .success(let measured)? = await runSpeedTest(key)
                {
                    measurement = measured
                }
            }
        }
        let now = deps.now()
        let resolved = RestoreyCore.resolveMacWideLimit(settings, measurement: measurement, at: now, calendar: .current)
        return (resolved.kiB, Self.macWideLimitLine(resolved, settings: settings, network: key, now: now, calendar: .current))
    }

    /// "Mac-wide upload limit 19 MB/s: 50% of 38 MB/s measured on “Kerr Home” today, inside 8:00 am–6:00 pm weekdays".
    static func macWideLimitLine(
        _ resolved: ResolvedMacWideLimit, settings: NetworkSettings, network: NetworkKey?, now: Date, calendar: Calendar
    ) -> String {
        let limit: String
        switch (resolved.kiB, settings.uploadLimit) {
        case (nil, _): limit = "none"
        case (let kiB?, .rate(_, let unit)): limit = rateText(kiB: kiB, unit: unit)
        case (let kiB?, _): limit = rateText(kiB: kiB, unit: kiB < 1024 ? .kilobytes : .megabytes)
        }
        let inside = settings.limitWindow.map { ", inside \(windowText($0))" } ?? ""
        let how: String
        switch resolved.reason {
        case .noLimitSet: how = "no limit set"
        case .outsideWindow: how = "outside \(settings.limitWindow.map(windowText) ?? "the window")"
        case .rate: how = "a fixed rate\(inside)"
        case .percentNotMeasured:
            how = network.map { "not measured on \($0.logName) yet" } ?? "not measured: no network"
        case .percentOf(let measurement):
            let percent = if case .percent(let percent) = settings.uploadLimit { percent } else { 0 }
            let speed = rateText(kiB: Int(measurement.bitsPerSecond / 8 / 1024), unit: .megabytes)
            let on = network.map { " on \($0.logName)" } ?? ""
            how = "\(percent)% of \(speed) measured\(on) \(dayText(measurement.measuredAt, now: now, calendar: calendar))\(inside)"
        }
        return "Mac-wide upload limit \(limit): \(how)"
    }

    /// "500 KB/s", "4.77 MB/s".
    static func rateText(kiB: Int, unit: UploadLimitUnit) -> String {
        switch unit {
        case .kilobytes: "\(kiB) KB/s"
        case .megabytes: "\(FormValidation.uploadLimitText(kiB: kiB)) MB/s"
        }
    }

    /// "8:00 am–6:00 pm weekdays".
    static func windowText(_ window: LimitWindow) -> String {
        func time(_ minute: Int) -> String {
            let hour = minute / 60 % 24
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return String(format: "%d:%02d %@", twelve, minute % 60, hour < 12 ? "am" : "pm")
        }
        let days = switch window.days {
        case .everyDay: "every day"
        case .weekdays: "weekdays"
        case .weekends: "weekends"
        }
        return "\(time(window.startMinute))–\(time(window.endMinute)) \(days)"
    }

    /// "today", "yesterday", or the date ("14 Jan 2027").
    static func dayText(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
