import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The agent's upload speed tests (the upload-limit design, "Measurements"): the tester's joining and records, and the
/// runner's daily test. `networkQuality` is always the `FakeSpeedTest` stand-in.
@Suite(.timeLimit(.minutes(3)))
struct SpeedTesterTests {
    // MARK: The tester

    struct World {
        let directory: URL
        let clock = FixtureClock()
        let fake: FakeSpeedTest
        let logs = Locked<[String]>([])
        let tester: SpeedTester

        init(_ results: [FakeSpeedTest.Outcome] = [.success(320_000_000)]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-speeds-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let clock = clock
            let fake = FakeSpeedTest(results, now: { clock.now })
            self.fake = fake
            let logs = logs
            tester = SpeedTester(
                store: AgentState.uploadSpeedsStore(in: directory), run: { await fake.run() }, now: { clock.now },
                log: { line in logs.mutate { $0.append(line) } })
        }

        var file: URL { directory.appendingPathComponent(UploadSpeedsFile.fileName) }

        /// A second tester on the same file, as after the agent restarts.
        func reloaded() -> SpeedTester {
            let clock = clock
            return SpeedTester(store: AgentState.uploadSpeedsStore(in: directory), run: { await fake.run() }, now: { clock.now }, log: { _ in })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    static let home = NetworkKey.wiFi(name: "Kerr Home")

    @Test func aTestInFlightIsJoined() async throws {
        let w = try World()
        defer { w.remove() }
        let gate = w.fake.holdCalls()
        let first = Task { await w.tester.test(Self.home) }
        #expect(await eventually { w.fake.calls.value == 1 })
        #expect(await w.tester.isTesting)
        // The same network, matched as the skip list matches names.
        let second = Task { await w.tester.test(.wiFi(name: " kerr home ")) }
        #expect(await eventually { await w.tester.callersWaiting == 2 })
        gate.open()
        let results = [await first.value, await second.value]
        #expect(w.fake.calls.value == 1)
        #expect(results[0] == results[1])
        #expect(await !w.tester.isTesting)
    }

    @Test func aSuccessIsKeptAndAFailureKeepsTheLatest() async throws {
        let w = try World([.success(320_000_000), .failure(.timedOut)])
        defer { w.remove() }
        let measured = try #require(try await w.tester.test(Self.home).get())
        #expect(measured.bitsPerSecond == 320_000_000)
        #expect(await w.tester.record(for: Self.home) == UploadSpeedRecord(latest: measured))

        w.clock.advance(60)
        #expect(await w.tester.test(Self.home) == .failure(.timedOut))
        let expected = UploadSpeedRecord(
            latest: measured, lastFailure: SpeedTestFailure(at: w.clock.now, reason: SpeedTestError.timedOut.message))
        #expect(await w.tester.record(for: Self.home) == expected)
        // Saved, not only in memory; other networks have nothing.
        #expect(await w.reloaded().record(for: Self.home) == expected)
        #expect(await w.tester.record(for: .ethernet) == nil)
    }

    @Test func aSuccessReplacesTheLastFailure() async throws {
        let w = try World([.failure(.unreadable), .success(80_000_000)])
        defer { w.remove() }
        _ = await w.tester.test(.ethernet)
        #expect(await w.tester.record(for: .ethernet)?.lastFailure != nil)
        _ = await w.tester.test(.ethernet)
        #expect(await w.tester.record(for: .ethernet)?.lastFailure == nil)
        #expect(await w.tester.record(for: .ethernet)?.latest?.bitsPerSecond == 80_000_000)
    }

    @Test func eachTestIsLoggedWithItsNetworkBytesAndDuration() async throws {
        let w = try World([.success(320_000_000), .failure(.exited(1))])
        defer { w.remove() }
        _ = await w.tester.test(Self.home)
        _ = await w.tester.test(.ethernet)
        let lines = w.logs.value
        try #require(lines.count == 2)
        #expect(lines[0].hasPrefix("Upload speed test on “Kerr Home”: 320 Mbit/s, 40000000 bytes sent, took "))
        #expect(lines[1].hasPrefix("Upload speed test on Ethernet failed after "))
        #expect(lines[1].hasSuffix(": \(SpeedTestError.exited(1).message)"))
    }

    @Test func testedTodayCountsASuccessOrAFailureOnTheDay() async throws {
        let w = try World([.success(320_000_000), .failure(.timedOut)])
        defer { w.remove() }
        let calendar = Calendar.current
        #expect(await !w.tester.testedToday(Self.home, calendar: calendar))
        _ = await w.tester.test(Self.home)
        #expect(await w.tester.testedToday(Self.home, calendar: calendar))
        #expect(await !w.tester.testedToday(.ethernet, calendar: calendar))
        _ = await w.tester.test(.ethernet)
        #expect(await w.tester.testedToday(.ethernet, calendar: calendar), "a failure counts too")
        w.clock.advance(TimeInterval(PlanRunner.day))
        #expect(await !w.tester.testedToday(Self.home, calendar: calendar))
    }

    @Test func waitUntilIdleReturnsAtOnceWithNoTestAndAfterOne() async throws {
        let w = try World()
        defer { w.remove() }
        await w.tester.waitUntilIdle()
        let gate = w.fake.holdCalls()
        let test = Task { await w.tester.test(Self.home) }
        #expect(await eventually { w.fake.calls.value == 1 })
        let idle = Locked(false)
        let waiter = Task {
            await w.tester.waitUntilIdle()
            idle.set(true)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!idle.value)
        gate.open()
        await waiter.value
        #expect(w.fake.answered.value == 1)
        _ = await test.value
    }

    /// The carried rule from Task 4: an `upload-speeds.json` that can't be read is no measurements, logged once, and a
    /// test still runs. The store never overwrites a file it can't read, so a newer version's file survives.
    @Test func anUnreadableFileIsNoMeasurementsAndIsLeftAlone() async throws {
        let w = try World()
        defer { w.remove() }
        let newer = Data(#"{"schemaVersion":99,"payload":{"records":{}}}"#.utf8)
        try newer.write(to: w.file)
        #expect(await w.tester.record(for: Self.home) == nil)
        #expect(await w.tester.record(for: .ethernet) == nil)
        let measured = await w.tester.test(Self.home)
        #expect(try measured.get().bitsPerSecond == 320_000_000)
        #expect(await w.tester.record(for: Self.home)?.latest != nil, "kept in memory")
        #expect(try Data(contentsOf: w.file) == newer)
        #expect(w.logs.value.filter { $0.contains("upload-speeds.json") }.count == 2, "\(w.logs.value)")
        _ = await w.tester.test(.ethernet)
        #expect(w.logs.value.filter { $0.contains("upload-speeds.json") }.count == 2, "each problem once")
    }

    /// A Release log never names the Wi-Fi network, and a decoding error's coding path holds the stored key
    /// (`wifi:<name>`): the log says what is wrong with the file, never the error's description.
    @Test func anUnreadableFileIsLoggedWithItsKindNeverTheNetworkName() async throws {
        let w = try World()
        defer { w.remove() }
        let corrupt = Data(#"{"schemaVersion":1,"payload":{"records":{"wifi:Secret Cafe":{"latest":{"bitsPerSecond":"fast"}}}}}"#.utf8)
        try corrupt.write(to: w.file)
        #expect(await w.tester.record(for: .ethernet) == nil)
        let lines = w.logs.value.filter { $0.contains("upload-speeds.json") }
        try #require(lines.count == 1)
        #expect(lines[0].hasSuffix("until a test runs: corrupt"), "\(lines[0])")
        #expect(!w.logs.value.joined().contains("Secret Cafe"))
        #expect(!w.logs.value.joined().contains("wifi:"))

        let newer = try World()
        defer { newer.remove() }
        try Data(#"{"schemaVersion":99,"payload":{}}"#.utf8).write(to: newer.file)
        #expect(await newer.tester.record(for: .ethernet) == nil)
        #expect(newer.logs.value.first?.hasSuffix("until a test runs: written by a newer Restorey (schema 99)") == true)
    }

    @Test func refusals() {
        let settings = NetworkSettings(uploadLimit: .percent(50), skipOnConstrainedNetwork: false, skippedWiFiNames: ["Café"])
        func check(_ network: NetworkState, _ name: String? = nil, running: Bool = false) -> SpeedTestRefusal? {
            SpeedTestRefusal.check(network: network, settings: settings, wiFiName: name, networkedCommandRunning: running)
        }
        #expect(check(.unsatisfied) == .noNetwork)
        // Never on mobile data, whatever the backup rule says.
        #expect(check(.satisfied(constrained: true, expensive: false)) == .constrained)
        #expect(check(.satisfied(constrained: false, expensive: true)) == .constrained)
        #expect(check(.satisfied(constrained: false, expensive: false, interface: .wiFi), " café ") == .skippedWiFi(" café "))
        #expect(check(.satisfied(constrained: false, expensive: false, interface: .wiFi), "Home") == nil)
        #expect(check(.satisfied(constrained: false, expensive: false), running: true) == .networkedCommandRunning)
        #expect(SpeedTestRefusal.skippedWiFi(" café ").message == "The upload speed isn’t tested on “café”, a Wi-Fi network backups skip")
        for refusal in [SpeedTestRefusal.noNetwork, .constrained, .skippedWiFi("A"), .networkedCommandRunning] {
            #expect(!refusal.message.hasSuffix("."))
        }
    }

    // MARK: The daily test

    static let percent = NetworkSettings(uploadLimit: .percent(50), skipOnConstrainedNetwork: true, skippedWiFiNames: [])

    @Test func theDailyTestRunsOncePerNetworkPerDay() async throws {
        let f = try await RunnerFixture.make(createRepository: false, networkSettings: Self.percent)
        defer { f.remove() }
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))
        await f.runner.beginDailySpeedTestIfDue()?.value
        #expect(f.speedTest.calls.value == 1)
        #expect(await f.speedTester.record(for: .ethernet)?.latest != nil)
        #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
        #expect(f.speedTest.calls.value == 1)

        // Another network has its own day.
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("Kerr Home")
        await f.runner.beginDailySpeedTestIfDue()?.value
        #expect(f.speedTest.calls.value == 2)
        #expect(await f.speedTester.record(for: .wiFi(name: "Kerr Home"))?.latest != nil)

        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: f.clock.now))
        f.clock.advance(Calendar.current.startOfDay(for: tomorrow).timeIntervalSince(f.clock.now) + 60)
        await f.runner.beginDailySpeedTestIfDue()?.value
        #expect(f.speedTest.calls.value == 3)
    }

    @Test func aRateOrNoLimitNeverRunsTheDailyTest() async throws {
        let rate = NetworkSettings(uploadLimit: .rate(kiB: 1024, unit: .megabytes), skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        for settings in [rate, NetworkSettings.defaults] {
            let f = try await RunnerFixture.make(createRepository: false, networkSettings: settings)
            defer { f.remove() }
            #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
            #expect(f.speedTest.calls.value == 0)
        }
    }

    @Test func noTestOnAConstrainedNetworkOrSkippedWiFi() async throws {
        var settings = Self.percent
        settings.skipOnConstrainedNetwork = false
        settings.skippedWiFiNames = ["Phone"]
        let f = try await RunnerFixture.make(createRepository: false, networkSettings: settings)
        defer { f.remove() }
        f.network.set(.satisfied(constrained: true, expensive: false, interface: .wiFi))
        f.wiFiName.set("Home")
        #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
        f.network.set(.satisfied(constrained: false, expensive: true, interface: .other))
        #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("phone")
        #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
        f.network.set(.unsatisfied)
        #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
        #expect(f.speedTest.calls.value == 0)

        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wiFi))
        f.wiFiName.set("Home")
        await f.runner.beginDailySpeedTestIfDue()?.value
        #expect(f.speedTest.calls.value == 1)
    }

    /// No test while restic runs any command against a networked repository; a backup to a folder doesn't count
    /// (Review Focus 2).
    @Test func noTestWhileANetworkedCommandRuns() async throws {
        let stub = try HeldResticStub()
        defer { stub.remove() }
        let f = try await RunnerFixture.make(executable: stub.executable, createRepository: false, networkSettings: Self.percent)
        defer { f.remove() }
        f.network.set(.satisfied(constrained: false, expensive: false, interface: .wired))
        // Measured yesterday, so no test runs before the backup and the daily one is due.
        let yesterday = f.clock.now.addingTimeInterval(-TimeInterval(PlanRunner.day))
        try await AgentState.uploadSpeedsStore(in: f.support).save(UploadSpeedsFile(records: [
            .ethernet: UploadSpeedRecord(latest: UploadSpeedMeasurement(bitsPerSecond: 80_000_000, measuredAt: yesterday)),
        ]))

        // A folder backup running: a test may run.
        let folder = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await stub.waitForBackups(1)
        await f.runner.beginDailySpeedTestIfDue()?.value
        #expect(f.speedTest.calls.value == 1)
        stub.release()
        _ = try await folder.value

        // A networked backup running: none may.
        stub.reset()
        let remote = try await f.addPlan("Remote", repository: "rest:http://127.0.0.1:9/one")
        f.clock.advance(TimeInterval(PlanRunner.day))
        let networked = Task { try await f.runner.runBackup(planID: remote, trigger: .scheduled) }
        try await stub.waitForBackups(1)
        #expect(await f.runner.beginDailySpeedTestIfDue() == nil)
        // The check every test passes through, also for one asked for before the command registered.
        #expect(await f.runner.runSpeedTest(.ethernet) == nil)
        #expect(f.speedTest.calls.value == 1)
        stub.release()
        _ = try await networked.value
        await f.runner.beginDailySpeedTestIfDue()?.value
        #expect(f.speedTest.calls.value == 2)
    }
}

/// A restic stand-in for runner tests that mustn't touch a repository: a `backup` writes its arguments to `args-<pid>`
/// and waits for `release()`; every command then exits 1.
struct HeldResticStub {
    let directory: URL
    let executable: URL
    private var releaseFile: URL { directory.appendingPathComponent("release") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-held-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("restic.sh")
        let path = directory.path
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then
              for arg in "$@"; do echo "$arg"; done > '\(path)'/args-$$.tmp
              mv '\(path)'/args-$$.tmp '\(path)'/args-$$
              while [ ! -f '\(path)/release' ]; do /bin/sleep 0.05; done
            fi
            exit 1

            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func release() {
        FileManager.default.createFile(atPath: releaseFile.path, contents: nil)
    }

    /// Forgets the backups seen so far and holds the next ones again.
    func reset() {
        let fm = FileManager.default
        try? fm.removeItem(at: releaseFile)
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasPrefix("args-") {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// The `--limit-upload` value of each backup started so far, by plan (nil: none).
    func limits() throws -> [UUID: String?] {
        var result: [UUID: String?] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
            where file.hasPrefix("args-") && !file.hasSuffix(".tmp")
        {
            let args = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let tag = try #require(args.first { $0.hasPrefix("--tag=restorey:") })
            let id = try #require(UUID(uuidString: String(tag.dropFirst("--tag=restorey:".count))))
            // Not `result[id] =`: assigning a nil `String?` through the subscript would remove the key.
            result.updateValue(args.firstIndex(of: "--limit-upload").map { args[$0 + 1] }, forKey: id)
        }
        return result
    }

    func waitForBackups(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while try limits().count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try limits().count == count)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
