import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The `fts` walker on a real folder (no dataless file can be made in a test), and the runner's use of the count.
@Suite(.timeLimit(.minutes(3)))
struct CloudOnlyWalkerTests {
    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-cloudonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aRealFolderWithASymlinkLoopCountsZeroAndTerminates() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a/b/file.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("a/loop"), withDestinationURL: root)

        var seen: [CloudOnlyEntry] = []
        FTSCloudOnlyWalker().walk(root: root.path) { seen.append($0); return .descend }
        #expect(seen.contains { $0.path.hasSuffix("a/b/file.txt") && !$0.isDataless })
        #expect(seen.first { $0.path.hasSuffix("a/loop") }?.isSymlink == true)
        // The loop is never entered: nothing is seen below it.
        #expect(!seen.contains { $0.path.contains("a/loop/") })

        let counter = CloudOnlyCounter(walker: FTSCloudOnlyWalker())
        #expect(counter.count(roots: [CloudOnlyRoot(path: root.path, isOtherProvider: false)], exclusions: [])
            == .counted(CloudOnlyCount(skipped: 0, includesOtherProviders: false)))
    }

    @Test func aMissingRootIsZeroAndNoCrash() {
        let counter = CloudOnlyCounter(walker: FTSCloudOnlyWalker())
        #expect(counter.count(roots: [CloudOnlyRoot(path: "/nonexistent-\(UUID().uuidString)", isOtherProvider: false)], exclusions: [])
            == .counted(CloudOnlyCount(skipped: 0, includesOtherProviders: false)))
    }

    @Test func theAgentCounterScopesToTheHomesFileProviderFolders() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Mobile Documents"), withIntermediateDirectories: true)
        let count = CloudOnlySkipped.counter(home: home)([home.path], [])
        #expect(count == CloudOnlyCount(skipped: 0, includesOtherProviders: false))
    }

    // MARK: In the runner

    @Test func theCountIsRecordedAfterABackupWithASnapshotWithoutChangingTheOutcome() async throws {
        let calls = Locked<[[String]]>([])
        let f = try await RunnerFixture.make(cloudOnlySkipped: { sources, _ in
            calls.mutate { $0.append(sources) }
            return CloudOnlyCount(skipped: 7, includesOtherProviders: false)
        })
        defer { f.remove() }
        try f.write("a.txt", "hello")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .success(snapshotID: .some) = record.outcome else {
            Issue.record("expected a success with a snapshot, got \(record.outcome)")
            return
        }
        #expect(record.cloudOnlySkipped == CloudOnlyCount(skipped: 7, includesOtherProviders: false))
        #expect(calls.value == [[f.source.path]])
        #expect(await f.history().lastBackupRecord?.cloudOnlySkipped?.skipped == 7)
        #expect(await f.pings() == [.success])
    }

    @Test func aGivenUpCountRecordsNilLogsItAndKeepsTheOutcome() async throws {
        let f = try await RunnerFixture.make(cloudOnlySkipped: { _, _ in nil })
        defer { f.remove() }
        try f.write("a.txt", "hello")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .success = record.outcome else {
            Issue.record("expected success, got \(record.outcome)")
            return
        }
        #expect(record.cloudOnlySkipped == nil)
        #expect(f.agentInfo.value.contains { $0.contains("Gave up counting cloud-only files") })
    }

    @Test func aFailedBackupIsNeverCounted() async throws {
        let calls = Locked<Int>(0)
        let f = try await RunnerFixture.make(cloudOnlySkipped: { _, _ in
            calls.mutate { $0 += 1 }
            return CloudOnlyCount(skipped: 1, includesOtherProviders: false)
        })
        defer { f.remove() }
        // A source that doesn't exist: refused before restic runs.
        try FileManager.default.removeItem(at: f.source)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .failed = record.outcome else {
            Issue.record("expected a failure, got \(record.outcome)")
            return
        }
        #expect(record.cloudOnlySkipped == nil)
        #expect(calls.value == 0)
    }
}
