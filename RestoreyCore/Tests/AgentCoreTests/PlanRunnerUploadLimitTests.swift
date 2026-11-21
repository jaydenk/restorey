import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The Mac-wide upload limit resolved at a backup's start (the upload-limit design, "Resolving the limit at a backup's
/// start"): the pre-backup speed test, the window, the network the backup starts on, and the wait for a test in flight.
/// restic is `HeldResticStub` and `networkQuality` is `FakeSpeedTest`; nothing reaches a real repository.
extension PlanRunnerTests {
    static let halfOfTheUpload = NetworkSettings(uploadLimit: .percent(50), skipOnConstrainedNetwork: true, skippedWiFiNames: [])
    static let remoteOne = "rest:http://127.0.0.1:9/one"

    /// A fixture whose plan backs up to a networked repository through `stub`.
    static func networkedFixture(_ stub: HeldResticStub, settings: NetworkSettings) async throws -> RunnerFixture {
        try await RunnerFixture.make(executable: stub.executable, createRepository: false, networkSettings: settings) {
            $0.repository = .raw(repository: remoteOne, environmentNames: [])
        }
    }

    static func measured(_ bitsPerSecond: Double, at date: Date) -> UploadSpeedRecord {
        UploadSpeedRecord(latest: UploadSpeedMeasurement(bitsPerSecond: bitsPerSecond, bytesSent: 1, measuredAt: date))
    }

    /// A window, every day, of one minute starting two hours after `date`'s local time: `date` is outside it.
    static func window(awayFrom date: Date) -> LimitWindow {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return LimitWindow(days: .everyDay, startMinute: (minute + 120) % 1440, endMinute: (minute + 121) % 1440)
    }

    func runLog(_ f: RunnerFixture, _ record: RunRecord) throws -> String {
        try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
    }

    /// Review Focus 2: two backups starting together on a network with no measurement share one test, and both
    /// resolve against its result (then share the limit as Ruling P2-7 says: the second to start counts the first).
    @Test func twoBackupsOnAnUnmeasuredNetworkShareOneTest() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        let f = try await Self.networkedFixture(stub, settings: Self.halfOfTheUpload)
        defer { f.remove() }
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))
        // A second test would measure something else.
        f.speedTest.answer(with: [.success(320_000_000), .success(80_000_000)])
        let two = try await f.addPlan("Two", repository: "rest:http://127.0.0.1:9/two")
        let gate = f.speedTest.holdCalls()

        let first = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        let second = Task { try await f.runner.runBackup(planID: two, trigger: .scheduled) }
        #expect(await eventually { await f.speedTester.callersWaiting == 2 })
        #expect(f.speedTest.calls.value == 1)
        #expect(try stub.limits().isEmpty, "neither backup starts during the test")
        gate.open()
        try await stub.waitForBackups(2)
        #expect(f.speedTest.calls.value == 1)
        // 50% of 320 Mbit/s is 19,531 KiB/s; the one that started second has half of it.
        #expect(Set(try stub.limits().values) == ["19531", "9765"])
        stub.release()
        _ = try await first.value
        _ = try await second.value
    }

    /// The test before the first backup fails: that backup runs with no Mac-wide limit and the failure is kept, with
    /// another network's measurement left as it was.
    @Test func aFailedPreBackupTestGivesNoMacWideLimit() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        stub.release()
        let f = try await Self.networkedFixture(stub, settings: Self.halfOfTheUpload)
        defer { f.remove() }
        let home = Self.measured(320_000_000, at: f.clock.now.addingTimeInterval(-3600))
        try await AgentState.uploadSpeedsStore(in: f.support).save(UploadSpeedsFile(records: [.wiFi(name: "Home"): home]))
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("Office")
        f.speedTest.answer(with: [.failure(.timedOut)])

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.speedTest.calls.value == 1)
        #expect(try stub.limits()[f.planID] == .some(nil), "no --limit-upload: the plan has none of its own")
        let office = await f.speedTester.record(for: .wiFi(name: "Office"))
        #expect(office == UploadSpeedRecord(lastFailure: SpeedTestFailure(at: f.clock.now, reason: SpeedTestError.timedOut.message)))
        #expect(await f.speedTester.record(for: .wiFi(name: "Home")) == home)
        #expect(try runLog(f, record).contains("Mac-wide upload limit none: not measured on “Office” yet"))
    }

    /// At most one test per network per calendar day: after the test before a backup fails, a later backup that day
    /// on the same network runs without one, and with no Mac-wide limit.
    @Test func aFailedPreBackupTestIsNotRepeatedTheSameDay() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        stub.release()
        let f = try await Self.networkedFixture(stub, settings: Self.halfOfTheUpload)
        defer { f.remove() }
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))
        f.speedTest.answer(with: [.failure(.timedOut), .success(320_000_000)])

        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.speedTest.calls.value == 1)
        stub.reset()
        stub.release()
        f.clock.advance(60)
        let second = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.speedTest.calls.value == 1)
        #expect(try stub.limits()[f.planID] == .some(nil))
        #expect(try runLog(f, second).contains("Mac-wide upload limit none: not measured on Ethernet yet"))
    }

    /// Outside the window there's no limit anyway, so the test before the first backup is left to the daily one.
    @Test func outsideTheWindowNoPreBackupTestRuns() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        stub.release()
        let f = try await Self.networkedFixture(stub, settings: Self.halfOfTheUpload)
        defer { f.remove() }
        var settings = Self.halfOfTheUpload
        settings.limitWindow = Self.window(awayFrom: f.clock.now)
        _ = try await f.state.saveNetworkSettings(settings)
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.speedTest.calls.value == 0)
        #expect(try stub.limits()[f.planID] == .some(nil))
        #expect(try runLog(f, record).contains("Mac-wide upload limit none: outside "))
    }

    /// Review Focus 4: the limit comes from the measurement of the network the backup starts on.
    @Test func aBackupResolvesAgainstTheNetworkItStartsOn() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        stub.release()
        let f = try await Self.networkedFixture(stub, settings: Self.halfOfTheUpload)
        defer { f.remove() }
        try await AgentState.uploadSpeedsStore(in: f.support).save(UploadSpeedsFile(records: [
            .wiFi(name: "Home"): Self.measured(320_000_000, at: f.clock.now),
            .wiFi(name: "Office"): Self.measured(80_000_000, at: f.clock.now),
        ]))
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("Office")

        let atTheOffice = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(try stub.limits()[f.planID] == "4882")
        #expect(try runLog(f, atTheOffice).contains(
            "Mac-wide upload limit 4.77 MB/s: 50% of 9.54 MB/s measured on “Office” today"))

        stub.reset()
        stub.release()
        f.wiFiName.set("home")
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(try stub.limits()[f.planID] == "19531")
        #expect(f.speedTest.calls.value == 0)
    }

    /// A networked command that wants to start during a test waits for it to end: restic isn't launched until the
    /// test has answered.
    @Test func aNetworkedCommandWaitsForATestInFlight() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        stub.release()
        let f = try await Self.networkedFixture(stub, settings: Self.halfOfTheUpload)
        defer { f.remove() }
        try await AgentState.uploadSpeedsStore(in: f.support).save(UploadSpeedsFile(records: [
            .ethernet: Self.measured(80_000_000, at: f.clock.now),
        ]))
        // The daily test on Wi-Fi, held; then the Mac moves to Ethernet, which is measured, so the backup needs no
        // test of its own.
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("Home")
        let gate = f.speedTest.holdCalls()
        let daily = try #require(await f.runner.beginDailySpeedTestIfDue())
        #expect(await eventually { f.speedTest.calls.value == 1 })
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))

        let backup = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(try stub.limits().isEmpty, "restic waits for the test")
        #expect(f.speedTest.answered.value == 0)
        gate.open()
        try await stub.waitForBackups(1)
        #expect(f.speedTest.answered.value == 1)
        #expect(try stub.limits()[f.planID] == "4882")
        _ = try await backup.value
        await daily.value
        #expect(f.speedTest.calls.value == 1)
    }

    /// The Wi-Fi name is read only on Wi-Fi and only when it matters: a percentage needs it for the network's key, and
    /// the preflight for the skip list. A rate, a wired network, or no list read nothing (and so never prompt).
    @Test func theWiFiNameIsReadOnlyWhenItMatters() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        stub.release()
        let rate = NetworkSettings(uploadLimit: .rate(kiB: 500, unit: .kilobytes), skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        let f = try await Self.networkedFixture(stub, settings: rate)
        defer { f.remove() }
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("Home")

        let fixed = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.wiFiNameReads.value == 0)
        #expect(try stub.limits()[f.planID] == "500")
        #expect(try runLog(f, fixed).contains("Mac-wide upload limit 500 KB/s: a fixed rate"))

        _ = try await f.state.saveNetworkSettings(.defaults)
        let none = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.wiFiNameReads.value == 0)
        #expect(try runLog(f, none).contains("Mac-wide upload limit none: no limit set"))

        _ = try await f.state.saveNetworkSettings(Self.halfOfTheUpload)
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.wiFiNameReads.value == 0)

        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(f.wiFiNameReads.value > 0)
        #expect(await f.speedTester.record(for: .wiFi(name: "Home"))?.latest != nil)
    }
}
