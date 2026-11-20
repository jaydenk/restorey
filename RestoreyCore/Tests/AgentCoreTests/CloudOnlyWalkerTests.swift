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
        #expect(count == .counted(CloudOnlyCount(skipped: 0, includesOtherProviders: false)))
    }

    @Test func skipChildrenOnARealDirectoryYieldsNothingBelowIt() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a/deep/f.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("b/g.txt"), atomically: true, encoding: .utf8)

        var seen: [String] = []
        FTSCloudOnlyWalker().walk(root: root.path) { entry in
            seen.append(entry.path)
            return entry.path.hasSuffix("/a") ? .skipChildren : .descend
        }
        #expect(seen.contains { $0.hasSuffix("/a") })
        #expect(!seen.contains { $0.contains("/a/") })
        #expect(seen.contains { $0.hasSuffix("b/g.txt") })
    }

    // MARK: In the runner

    private static func counted(_ n: Int) -> CloudOnlyCounter.Result {
        .counted(CloudOnlyCount(skipped: n, includesOtherProviders: false))
    }

    /// restic, then a chosen exit code for the backup (restic's own for anything else).
    private static func resticExiting(_ code: Int, in directory: URL) throws -> URL {
        let restic = try ResticBinary.require()
        let script = directory.appendingPathComponent("restic-\(code).sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then '\(restic.path)' "$@"; exit \(code); fi
            exec '\(restic.path)' "$@"

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func theCountIsRecordedAfterABackupWithASnapshotWithoutChangingTheOutcome() async throws {
        let calls = Locked<[[String]]>([])
        let f = try await RunnerFixture.make(cloudOnlySkipped: { sources, _ in
            calls.mutate { $0.append(sources) }
            return Self.counted(7)
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

    @Test func aWarningBackupIsCounted() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try await RunnerFixture.make(
            executable: try Self.resticExiting(3, in: dir), cloudOnlySkipped: { _, _ in Self.counted(4) })
        defer { f.remove() }
        try f.write("a.txt", "hello")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .warning = record.outcome else {
            Issue.record("expected a warning, got \(record.outcome)")
            return
        }
        #expect(record.cloudOnlySkipped?.skipped == 4)
    }

    @Test func aResticFailureIsNeverCounted() async throws {
        let calls = Locked<Int>(0)
        let f = try await RunnerFixture.make(cloudOnlySkipped: { _, _ in
            calls.mutate { $0 += 1 }
            return Self.counted(1)
        })
        defer { f.remove() }
        try f.write("a.txt", "one")
        try "not-the-password".write(to: f.passwordFile, atomically: true, encoding: .utf8)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        #expect(record.outcome == .wrongPassword)
        #expect(record.cloudOnlySkipped == nil)
        #expect(calls.value == 0)
    }

    @Test func aPausedBackupIsNeverCounted() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let restic = try ResticBinary.require()
        let script = dir.appendingPathComponent("slow.sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then
              echo '{"message_type":"status","percent_done":0.1,"total_files":1,"files_done":0,"total_bytes":1,"bytes_done":0}'
              exec /bin/sleep 30
            fi
            exec '\(restic.path)' "$@"

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let calls = Locked<Int>(0)
        let f = try await RunnerFixture.make(executable: script, gracePeriod: .seconds(2), cloudOnlySkipped: { _, _ in
            calls.mutate { $0 += 1 }
            return Self.counted(1)
        })
        defer { f.remove() }
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        _ = try await f.state.pause(f.planID, for: .oneHour)
        let record = try await run.value

        #expect(record.outcome == .paused)
        #expect(record.cloudOnlySkipped == nil)
        #expect(calls.value == 0)
    }

    @Test func aRefusedBackupIsNeverCounted() async throws {
        let calls = Locked<Int>(0)
        let f = try await RunnerFixture.make(cloudOnlySkipped: { _, _ in
            calls.mutate { $0 += 1 }
            return Self.counted(1)
        })
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.source)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        guard case .failed = record.outcome else {
            Issue.record("expected a failure, got \(record.outcome)")
            return
        }
        #expect(record.cloudOnlySkipped == nil)
        #expect(calls.value == 0)
    }

    @Test func aGivenUpCountRecordsNilAndLogsIt() async throws {
        let f = try await RunnerFixture.make(cloudOnlySkipped: { _, _ in .gaveUp })
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

    @Test func noCounterRecordsNilWithoutLoggingAGiveUp() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        try f.write("a.txt", "hello")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        #expect(record.cloudOnlySkipped == nil)
        #expect(!f.agentInfo.value.contains { $0.contains("Gave up counting") })
    }

    @Test func aStuckWalkIsAbandonedAtTheDeadlineAndItsLateResultDiscarded() async throws {
        let finished = Locked<Bool>(false)
        // The walk is held until the test lets it go, after the backup has returned (task 18: no assumption about
        // how long the backup takes). It blocks its own thread, never a Swift concurrency one.
        let release = DispatchSemaphore(value: 0)
        let f = try await RunnerFixture.make(
            cloudOnlySkipped: { _, _ in
                release.wait()
                finished.set(true)
                return Self.counted(9)
            }, cloudOnlyDeadline: 0.3)
        defer { f.remove() }
        // Should the backup throw, the walk's thread still ends (a second signal does nothing).
        defer { release.signal() }
        try f.write("a.txt", "hello")

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)

        #expect(!finished.value)
        release.signal()
        guard case .success = record.outcome else {
            Issue.record("expected success, got \(record.outcome)")
            return
        }
        #expect(record.cloudOnlySkipped == nil)
        #expect(f.agentInfo.value.contains { $0.contains("Gave up counting cloud-only files") })
        // The walk finishes later; nothing it returns reaches the history.
        while !finished.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await f.history().lastBackupRecord?.cloudOnlySkipped == nil)
    }

    /// Task 18 fix round 1: one walk at a time. While a walk is stuck past its deadline, later backups don't walk at
    /// all (logged once for the episode), so a wedged File Provider holds one thread, not one per backup. Once it
    /// returns, the next backup walks again.
    @Test func aStuckWalkIsNotJoinedByAnother() async throws {
        let walks = Locked(0)
        let release = DispatchSemaphore(value: 0)
        let f = try await RunnerFixture.make(
            cloudOnlySkipped: { _, _ in
                let first = walks.exchange(walks.value + 1) == 0
                if first { release.wait() }
                return Self.counted(9)
            }, cloudOnlyDeadline: 0.3)
        defer { f.remove() }
        defer { release.signal() }
        try f.write("a.txt", "hello")

        let stuck = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        let second = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        let third = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect([stuck, second, third].map(\.cloudOnlySkipped) == [nil, nil, nil])
        #expect(walks.value == 1, "no second walk while the first is stuck")
        #expect(f.agentInfo.value.filter { $0.contains("Not counting cloud-only files") }.count == 1)

        release.signal()
        while f.runner.cloudOnlyWalkGate.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let after = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(after.cloudOnlySkipped == CloudOnlyCount(skipped: 9, includesOtherProviders: false))
        #expect(walks.value == 2)
    }
}
