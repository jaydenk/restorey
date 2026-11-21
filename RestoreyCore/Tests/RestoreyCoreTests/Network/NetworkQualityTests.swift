import Foundation
import Testing
@testable import RestoreyCore

struct NetworkQualityTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.url("networkQuality/\(name)"))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Parsing

    @Test func parsesUploadThroughputAndBytes() throws {
        let draft = try NetworkQuality.parse(stdout: fixture("upload-full.json")).get()
        #expect(draft.bitsPerSecond == 38_412_345)
        #expect(draft.bytesSent == 71_234_567)
    }

    @Test func zeroThroughputIsNoUploadMeasured() throws {
        #expect(NetworkQuality.parse(stdout: try fixture("upload-zero.json")) == .failure(.noUploadMeasured))
    }

    @Test func truncatedJSONIsUnreadable() throws {
        #expect(NetworkQuality.parse(stdout: try fixture("upload-truncated.json")) == .failure(.unreadable))
        #expect(NetworkQuality.parse(stdout: Data()) == .failure(.unreadable))
        #expect(NetworkQuality.parse(stdout: Data("[1,2]".utf8)) == .failure(.unreadable))
    }

    @Test func aMissingOrUnusableThroughputIsNeverStored() {
        func parse(_ json: String) -> Result<UploadSpeedMeasurementDraft, SpeedTestError> {
            NetworkQuality.parse(stdout: Data(json.utf8))
        }
        #expect(parse(#"{"base_rtt":10}"#) == .failure(.noUploadMeasured))
        #expect(parse(#"{"ul_throughput":-5}"#) == .failure(.noUploadMeasured))
        #expect(parse(#"{"ul_throughput":null}"#) == .failure(.noUploadMeasured))
        #expect(parse(#"{"ul_throughput":"fast"}"#) == .failure(.unreadable))
        #expect(parse(#"{"ul_throughput":true}"#) == .failure(.unreadable))
    }

    @Test func missingBytesStillGivesASpeed() throws {
        let draft = try NetworkQuality.parse(stdout: Data(#"{"ul_throughput":1000000.5}"#.utf8)).get()
        #expect(draft.bitsPerSecond == 1_000_000.5)
        #expect(draft.bytesSent == nil)
    }

    @Test func theMessagesMatchTheSpec() {
        #expect(SpeedTestError.couldNotStart("no such file").message == "The upload speed test couldn’t start: no such file")
        #expect(SpeedTestError.timedOut.message == "The upload speed test didn’t finish in time")
        #expect(SpeedTestError.exited(3).message == "The upload speed test stopped with an error (3)")
        #expect(SpeedTestError.unreadable.message == "The upload speed test’s result couldn’t be read")
        #expect(SpeedTestError.noUploadMeasured.message == "The upload speed test didn’t measure any upload")
    }

    @Test func theCommandLineIsUploadOnlyJSONBounded() {
        #expect(NetworkQuality.arguments == ["-d", "-c", "-M", "20"])
        #expect(NetworkQuality.executable.path == "/usr/bin/networkQuality")
    }

    // MARK: Running (stand-in scripts, never the real tool)

    private func withScripts<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-nq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    private func script(_ name: String, _ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func aSuccessfulRunIsStampedWithTheClock() async throws {
        try await withScripts { directory in
            let full = Fixtures.url("networkQuality/upload-full.json").path
            let ok = try script("ok.sh", "cat '\(full)'", in: directory)
            let result = await NetworkQuality.run(executable: ok, now: { now })
            #expect(result == .success(UploadSpeedMeasurement(bitsPerSecond: 38_412_345, bytesSent: 71_234_567, measuredAt: now)))
        }
    }

    @Test func aNonZeroExitIsReportedWithItsCode() async throws {
        try await withScripts { directory in
            let fail = try script("fail.sh", "echo oops >&2; exit 3", in: directory)
            #expect(await NetworkQuality.run(executable: fail, now: { now }) == .failure(.exited(3)))
        }
    }

    @Test func aMissingExecutableCouldNotStart() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-nq-missing-\(UUID().uuidString)")
        guard case .failure(.couldNotStart) = await NetworkQuality.run(executable: missing, now: { now }) else {
            Issue.record("expected couldNotStart")
            return
        }
    }

    @Test func aRunPastTheBoundTimesOutAndIsKilled() async throws {
        try await withScripts { directory in
            let pidFile = directory.appendingPathComponent("pid")
            let sleeper = try script("sleep.sh", "echo $$ > '\(pidFile.path)'\nexec sleep 60", in: directory)
            let started = ContinuousClock.now
            let result = await NetworkQuality.run(executable: sleeper, now: { now }, bound: .seconds(1))
            #expect(result == .failure(.timedOut))
            #expect(ContinuousClock.now - started < .seconds(8))
            let pid = try #require(pid_t(String(contentsOfFile: pidFile.path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(!isRunning(pid), "the sleeper must not outlive the run")
        }
    }

    @Test func aRunThatIgnoresTerminateIsKilledAfterTheGrace() async throws {
        try await withScripts { directory in
            let pidFile = directory.appendingPathComponent("pid")
            let stubborn = try script("stubborn.sh", "trap '' TERM\necho $$ > '\(pidFile.path)'\nexec sleep 60", in: directory)
            let result = await NetworkQuality.run(
                executable: stubborn, now: { now }, bound: .seconds(1), killAfter: .seconds(1))
            #expect(result == .failure(.timedOut))
            let pid = try #require(pid_t(String(contentsOfFile: pidFile.path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(!isRunning(pid), "SIGKILL must follow when terminate is ignored")
        }
    }

    @Test func aSuccessfulExitWithAnUnreadableResultIsUnreadable() async throws {
        try await withScripts { directory in
            let garbage = try script("garbage.sh", "echo 'not json'", in: directory)
            #expect(await NetworkQuality.run(executable: garbage, now: { now }) == .failure(.unreadable))
        }
    }
}
