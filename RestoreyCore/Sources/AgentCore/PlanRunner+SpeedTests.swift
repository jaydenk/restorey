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
        await deps.state.speedTestBegan(on: key)
        let result = await tester.test(key)
        speedTestsAsked -= 1
        if speedTestsAsked == 0 {
            let waiters = speedTestWaiters
            speedTestWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        await refreshUploadSpeedStatus(endingTest: true)
        return result
    }

    /// "Test now" (`AgentXPC.runUploadSpeedTest`): the test on the current network, through `runSpeedTest` like every
    /// other test so it can't overlap a networked restic command. Returns the status once it has ended, a failed test
    /// included. Refused when it may not run (`SpeedTestRefusal`).
    func testUploadSpeedNow() async throws -> AgentStatus {
        guard deps.speedTester != nil else { throw AgentError.operationFailed("The upload speed can’t be tested now") }
        let settings = await deps.state.networkSettings
        let network = await currentNetwork(settings)
        if let refusal = SpeedTestRefusal.check(
            network: network.state, settings: settings, wiFiName: network.wiFiName,
            networkedCommandRunning: !networkedCommands.isEmpty)
        {
            throw AgentError.speedTestRefused(refusal)
        }
        guard let key = network.key else { throw AgentError.speedTestRefused(.noNetwork) }
        // No suspension between the check above and this call, so no networked command registers in between.
        guard await runSpeedTest(key) != nil else {
            throw AgentError.speedTestRefused(.networkedCommandRunning)
        }
        return await deps.state.status()
    }

    /// Gives the status the network the Mac is on now and what is kept for it, pushing it if that changed. The
    /// scheduler's tick calls it, so a change of network shows within a minute or at the next nudge.
    func refreshUploadSpeedStatus(endingTest: Bool = false) async {
        let settings = await deps.state.networkSettings
        let network = await currentNetwork(settings)
        var record: UploadSpeedRecord?
        if let key = network.key, let tester = deps.speedTester { record = await tester.record(for: key) }
        await deps.state.noteUploadSpeed(network: network.key, record: record, endingTest: endingTest)
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

    /// The network the Mac is on now and its key. The Wi-Fi name is read only on Wi-Fi when something needs it: a
    /// percentage (its measurement belongs to the network) or a skip list with names (a test is refused on a skipped
    /// network); CoreWLAN never prompts for Location, it answers nil without it.
    func currentNetwork(_ settings: NetworkSettings) async -> (state: NetworkState, key: NetworkKey?, wiFiName: String?) {
        let environment = await deps.preflightEnvironment()
        var wiFiName: String?
        if case .satisfied(_, _, .wiFi) = environment.network, settings.needsWiFiNameForSpeedTests {
            wiFiName = environment.currentWiFiName()
        }
        return (environment.network, networkKey(for: environment.network, wiFiName: wiFiName), wiFiName)
    }

    // MARK: Resolving the limit at a backup's start

    /// The Mac-wide limit for a backup to a networked repository starting now, and the run log's line saying how it was
    /// resolved. With a percentage set, on a network with no measurement and not tested yet today, inside the window
    /// (or with none), and on a network that may be tested, the test runs first; if it fails, or can't run because another networked command
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
                    // At most once per network per day: a test that failed earlier today isn't run again.
                    !(await tester.testedToday(key, calendar: .current)),
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

    /// A log reads the same on every Mac, so its times and dates are Australian English whatever the Mac's region.
    private static let logLocale = Locale(identifier: "en_AU")

    /// "Mac-wide upload limit 19 MB/s: 50% of 38 MB/s measured on Wi-Fi today, inside 8:00 am–6:00 pm weekdays" (a Debug
    /// build names the Wi-Fi network: `NetworkKey.logName`).
    static func macWideLimitLine(
        _ resolved: ResolvedMacWideLimit, settings: NetworkSettings, network: NetworkKey?, now: Date, calendar: Calendar
    ) -> String {
        let limit: String
        switch (resolved.kiB, settings.uploadLimit) {
        case (nil, _): limit = "none"
        case (let kiB?, .rate(_, let unit)): limit = UploadLimitText.rateText(kiB: kiB, unit: unit)
        case (let kiB?, _): limit = UploadLimitText.rateText(kiB: kiB, unit: kiB < 1024 ? .kilobytes : .megabytes)
        }
        let inside = settings.limitWindow.map { ", inside \(UploadLimitText.windowText($0, locale: Self.logLocale))" } ?? ""
        let how: String
        switch resolved.reason {
        case .noLimitSet: how = "no limit set"
        case .outsideWindow: how = "outside \(settings.limitWindow.map { UploadLimitText.windowText($0, locale: Self.logLocale) } ?? "the window")"
        case .rate: how = "a fixed rate\(inside)"
        case .percentNotMeasured:
            how = network.map { "not measured on \($0.logName) yet" } ?? "not measured: no network"
        case .percentOf(let measurement):
            let percent = if case .percent(let percent) = settings.uploadLimit { percent } else { 0 }
            let speed = UploadLimitText.rateText(kiB: Int(measurement.bitsPerSecond / 8 / 1024), unit: .megabytes)
            let on = network.map { " on \($0.logName)" } ?? ""
            how = "\(percent)% of \(speed) measured\(on) \(UploadLimitText.dayText(measurement.measuredAt, now: now, calendar: calendar, locale: Self.logLocale))\(inside)"
        }
        return "Mac-wide upload limit \(limit): \(how)"
    }
}

extension NetworkSettings {
    /// Whether the speed tests need the Wi-Fi name: the limit is a percentage, or the skip list has names.
    fileprivate var needsWiFiNameForSpeedTests: Bool {
        if case .percent = uploadLimit { return true }
        return !skippedWiFiNames.isEmpty
    }
}
