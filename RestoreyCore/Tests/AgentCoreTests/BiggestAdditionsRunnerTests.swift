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

    /// A folder's line as restic 0.19.1 prints it: its own tree's size in the metadata fields (Task 16f).
    private static func folder(_ action: String, _ item: String, _ listing: Int) -> String {
        #"{"message_type":"verbose_status","action":"\#(action)","item":"\#(item)","duration":0.1,"data_size":0,"data_size_in_repo":0,"metadata_size":\#(listing),"metadata_size_in_repo":\#(listing),"total_files":0}"#
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
            totalBytesAdded: 3_000, listingsBytesAdded: 0))
        // The record as committed carries them too.
        #expect(await s.f.history().recent.first { $0.id == record.id }?.biggestAdditions == record.biggestAdditions)

        let text = try log(s.f, record)
        let lines = text.split(separator: "\n")
        #expect(lines.filter { $0.contains("Biggest additions") }.count == 1)
        #expect(lines.contains {
            $0.hasSuffix(" Biggest additions (files added 3 kB, folder listings 0 B to the repository): \(source)/Pictures/big.jpg 2 kB, "
                + "\(source)/notes.txt 1 kB; by folder: \(source)/Pictures 2 kB, \(source) 1 kB")
        })
        #expect(!text.contains("verbose_status"))
        #expect(!text.contains("\(source)/old"))
        #expect(!text.contains("\(source)/broken"))
    }

    /// Task 16f: folders' listings count towards the folder and a total of their own; a shortfall against restic's
    /// `data_added_packed` of more than 10% gets a line of its own in the run log, and nothing else.
    @Test func folderListingsAreRecordedAndAShortfallIsLogged() async throws {
        let s = try await fixture { source in
            [
                Self.verbose("new", "\(source)/Pictures/big.jpg", 2_000),
                Self.folder("new", "\(source)/Pictures/", 400),
                Self.folder("modified", "\(source)/", 300),
                Self.folder("unchanged", "\(source)/Old/", 0),
                // restic's summary: 3,000 bytes, so 2,700 counted is within 10%.
                Self.summary,
            ]
        }
        defer { s.remove() }
        let source = await s.f.plan().sources[0]
        let record = try await s.f.runner.runBackup(planID: s.f.planID, trigger: .manual)
        #expect(record.biggestAdditions == BiggestAdditions(
            files: [.init(path: "\(source)/Pictures/big.jpg", bytesAdded: 2_000)],
            folders: [.init(path: "\(source)/Pictures", bytesAdded: 2_400), .init(path: source, bytesAdded: 300)],
            totalBytesAdded: 2_000, listingsBytesAdded: 700))
        let text = try log(s.f, record)
        #expect(text.contains(" Biggest additions (files added 2 kB, folder listings 700 B to the repository): "))
        #expect(!text.contains("less than the"))

        let short = try await fixture { source in
            [Self.verbose("new", "\(source)/a", 1_000), Self.folder("modified", "\(source)/", 500), Self.summary]
        }
        defer { short.remove() }
        let shortRecord = try await short.f.runner.runBackup(planID: short.f.planID, trigger: .manual)
        #expect(shortRecord.outcome == .success(snapshotID: "abc123"))
        let shortText = try log(short.f, shortRecord)
        #expect(shortText.contains(" Biggest additions: files (1 kB) and folder listings (500 B) come to 1.5 kB, 1.5 kB less "
            + "than the 3 kB restic says the backup added to the repository (data_added_packed)\n"))
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
    /// Task 16f's acceptance check: what the verbose lines add up to (files and folder listings) is restic's own
    /// `data_added_packed` less only the root's tree, which restic reports with no node and so never prints: a few
    /// hundred bytes, well inside 10%.
    private static func expectCloseToResticsTotal(_ record: RunRecord, label: String) throws {
        let additions = try #require(record.biggestAdditions)
        let packed = Int64(try #require(record.summary?.dataAddedPacked))
        let counted = additions.totalBytesAdded + (additions.listingsBytesAdded ?? 0)
        #expect(counted <= packed, "\(label): \(counted) of \(packed)")
        #expect(packed - counted < 2_048, "\(label): \(counted) of \(packed)")
        #expect(BiggestAdditionsText.shortfallLogLine(additions, dataAddedPacked: Int(packed)) == nil)
    }

    @Test(.timeLimit(.minutes(3))) func resticReportsTheFileThatWasAdded() async throws {
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
        // The source's own listing counts with its files; the folders restic records above it count in the total only.
        let firstListings = try #require(firstAdditions.listingsBytesAdded)
        #expect(firstAdditions.folders.map(\.path) == [source])
        #expect(firstAdditions.folders[0].bytesAdded > firstAdditions.totalBytesAdded)
        #expect(firstAdditions.folders[0].bytesAdded < firstAdditions.totalBytesAdded + firstListings)
        try Self.expectCloseToResticsTotal(first, label: "first")

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
        // later/ holds the file and its own new listing; the source's listing changed because later/ is new in it.
        #expect(secondAdditions.folders.map(\.path) == [later, source])
        #expect(secondAdditions.folders[0].bytesAdded > secondAdditions.files[0].bytesAdded)
        #expect(secondAdditions.totalBytesAdded == secondAdditions.files[0].bytesAdded)
        #expect((secondAdditions.listingsBytesAdded ?? 0) > 0)
        try Self.expectCloseToResticsTotal(second, label: "second")
        let log = try String(contentsOf: f.logs.appendingPathComponent(second.logFile), encoding: .utf8)
        #expect(log.contains("Biggest additions (files added"))
        #expect(log.contains(", folder listings "))
        #expect(!log.contains("less than the"))
        #expect(log.contains("--verbose"))
        #expect(!log.contains("verbose_status"))
    }
}
