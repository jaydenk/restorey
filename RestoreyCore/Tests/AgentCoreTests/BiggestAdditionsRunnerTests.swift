import Foundation
import Testing
@testable import AgentCore
@testable import RestoreyCore

/// Task 16d: a backup records its biggest additions from restic's verbose lines, and its run log gets one line about
/// them and none of the verbose lines themselves.
struct BiggestAdditionsRunnerTests {
    private static func verbose(_ action: String, _ item: String, _ inRepo: Int) -> String {
        #"{"message_type":"verbose_status","action":"\#(action)","item":"\#(item)","duration":0.1,"data_size":\#(inRepo),"data_size_in_repo":\#(inRepo),"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#
    }

    private static let summary = #"{"message_type":"summary","files_new":2,"data_added":3000,"data_added_packed":3000,"snapshot_id":"abc123"}"#

    /// A fixture whose restic is a stand-in: its backup prints `lines(source)` on stdout (`source` is the plan's), then
    /// exits `exit`. The stand-in lives beside the fixture's folder; `remove` takes both.
    private struct StubFixture {
        let f: RunnerFixture
        let stub: URL
        func remove() {
            f.remove()
            try? FileManager.default.removeItem(at: stub)
        }
    }

    private func fixture(exit: Int = 0, _ lines: (String) -> [String]) async throws -> StubFixture {
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-additions-\(UUID().uuidString).sh")
        func write(_ lines: [String]) throws {
            try """
                #!/bin/sh
                [ "$1" = cat ] && exit 10
                [ "$1" = backup ] || exit 0
                \(lines.map { "echo '\($0)'" }.joined(separator: "\n"))
                exit \(exit)

                """.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        try write([])
        let f: RunnerFixture
        do {
            f = try await RunnerFixture.make(executable: stub)
        } catch {
            try? FileManager.default.removeItem(at: stub)
            throw error
        }
        let fixture = StubFixture(f: f, stub: stub)
        do {
            try write(lines(await f.plan().sources[0]))
        } catch {
            fixture.remove()
            throw error
        }
        return fixture
    }

    private func log(_ f: RunnerFixture, _ record: RunRecord) throws -> String {
        try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
    }

    @Test func aBackupThatMadeASnapshotRecordsItsBiggestAdditionsAndLogsOneLine() async throws {
        let s = try await fixture { source in
            [
                Self.verbose("unchanged", "\(source)/old", 0),
                Self.verbose("new", "\(source)/Pictures/big.jpg", 2_000),
                Self.verbose("modified", "\(source)/notes.txt", 1_000),
                Self.verbose("modified", "\(source)/", 0),
                // Cut short: skipped, and the run goes on.
                #"{"message_type":"verbose_status","action":"new","item":"\#(source)/broken"#,
                Self.summary,
            ]
        }
        defer { s.remove() }
        let source = await s.f.plan().sources[0]
        let record = try await s.f.runner.runBackup(planID: s.f.planID, trigger: .manual)
        #expect(record.outcome == .success(snapshotID: "abc123"))
        #expect(record.biggestAdditions == BiggestAdditions(
            files: [.init(path: "\(source)/Pictures/big.jpg", bytesAdded: 2_000), .init(path: "\(source)/notes.txt", bytesAdded: 1_000)],
            folders: [.init(path: "\(source)/Pictures", bytesAdded: 2_000), .init(path: source, bytesAdded: 1_000)],
            totalBytesAdded: 3_000))
        // The record as committed carries them too.
        #expect(await s.f.history().recent.first { $0.id == record.id }?.biggestAdditions == record.biggestAdditions)

        let text = try log(s.f, record)
        let lines = text.split(separator: "\n")
        #expect(lines.filter { $0.contains("Biggest additions") }.count == 1)
        #expect(lines.contains {
            $0.hasSuffix(" Biggest additions (files added 3 kB to the repository): \(source)/Pictures/big.jpg 2 kB, "
                + "\(source)/notes.txt 1 kB; by folder: \(source)/Pictures 2 kB, \(source) 1 kB")
        })
        #expect(!text.contains("verbose_status"))
        #expect(!text.contains("\(source)/old"))
        #expect(!text.contains("\(source)/broken"))
    }

    @Test func aWarningBackupRecordsThemToo() async throws {
        let s = try await fixture(exit: 3) { source in [Self.verbose("new", "\(source)/a", 10), Self.summary] }
        defer { s.remove() }
        let record = try await s.f.runner.runBackup(planID: s.f.planID, trigger: .manual)
        #expect(record.outcome == .warning(unreadable: 1))
        #expect(record.biggestAdditions?.files.map(\.bytesAdded) == [10])
    }

    @Test func aBackupWithoutASnapshotRecordsNone() async throws {
        let unchanged = #"{"message_type":"summary","files_new":0,"files_unmodified":3}"#
        let cases: [(exit: Int, lines: (String) -> [String])] = [
            (0, { [Self.verbose("modified", "\($0)/", 0), unchanged] }),
            (1, { [Self.verbose("new", "\($0)/a", 10)] }),
        ]
        for c in cases {
            let s = try await fixture(exit: c.exit, c.lines)
            defer { s.remove() }
            let record = try await s.f.runner.runBackup(planID: s.f.planID, trigger: .manual)
            #expect(record.outcome != .success(snapshotID: "abc123"))
            #expect(record.biggestAdditions == nil)
            #expect(try !log(s.f, record).contains("Biggest additions"))
        }
    }

    @Test func aResticThatPrintsNoVerboseLinesRecordsNoneAndSaysSo() async throws {
        let s = try await fixture { _ in [Self.summary] }
        defer { s.remove() }
        let record = try await s.f.runner.runBackup(planID: s.f.planID, trigger: .manual)
        #expect(record.outcome == .success(snapshotID: "abc123"))
        #expect(record.biggestAdditions == nil)
        #expect(try log(s.f, record).contains("Biggest additions: restic didn't report them"))
    }

    @Test func onlyABackupThatMadeASnapshotKeepsThem() {
        let collector = BiggestAdditionsCollector(sources: ["/s"])
        collector.collect(.verboseStatus(VerboseItem(action: "new", item: "/s/a", dataSizeInRepo: 1)))
        #expect(PlanRunner.biggestAdditions(.backup, .success(snapshotID: "a"), collector) != nil)
        #expect(PlanRunner.biggestAdditions(.backup, .warning(unreadable: 1), collector) != nil)
        for outcome: RunOutcome in [
            .success(snapshotID: nil), .unchanged, .paused, .cancelled, .stoppedBySystem, .interrupted,
            .failed(exitCode: 1, reason: "x"), .locked,
        ] {
            #expect(PlanRunner.biggestAdditions(.backup, outcome, collector) == nil, "\(outcome)")
        }
        #expect(PlanRunner.biggestAdditions(.backup, .success(snapshotID: "a"), nil) == nil)
        #expect(PlanRunner.biggestAdditions(.prune, .success(snapshotID: "a"), collector) == nil)
    }

    // MARK: The real restic

    /// Against the vendored restic 0.19.1: the first backup's biggest file is the big one, and the next backup's is the
    /// one file added since, with the unchanged big one nowhere in its lists.
    @Test(.timeLimit(.minutes(2))) func resticReportsTheFileThatWasAdded() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("small.txt", "hello")
        try await f.writeRandomFiles(count: 1, megabytes: 2)
        let first = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        guard case .success(snapshotID: .some) = first.outcome else {
            Issue.record("first backup: \(first.outcome)")
            return
        }
        let source = await f.plan().sources[0]
        let firstAdditions = try #require(first.biggestAdditions)
        let big = try #require(firstAdditions.files.first)
        #expect(big.path.hasPrefix(source + "/"))
        #expect(big.path != source + "/small.txt")
        // Random data doesn't compress: about its 2 MiB, plus a little for encryption.
        #expect(big.bytesAdded > 2_000_000 && big.bytesAdded < 2_200_000)
        #expect(firstAdditions.files.map(\.path).last == source + "/small.txt")
        #expect(firstAdditions.folders == [.init(path: source, bytesAdded: firstAdditions.totalBytesAdded)])

        let later = source + "/later"
        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: true)
        try Data((0..<300_000).map { _ in UInt8.random(in: 0...255) }).write(to: URL(fileURLWithPath: later + "/added.bin"))
        let second = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        guard case .success(snapshotID: .some) = second.outcome else {
            Issue.record("second backup: \(second.outcome)")
            return
        }
        let secondAdditions = try #require(second.biggestAdditions)
        #expect(secondAdditions.files.map(\.path) == [later + "/added.bin"])
        #expect(secondAdditions.folders.map(\.path) == [later])
        #expect(secondAdditions.totalBytesAdded == secondAdditions.files[0].bytesAdded)
        let log = try String(contentsOf: f.logs.appendingPathComponent(second.logFile), encoding: .utf8)
        #expect(log.contains("Biggest additions (files added"))
        #expect(log.contains("--verbose"))
        #expect(!log.contains("verbose_status"))
    }
}
