import Foundation
import Synchronization
import Testing
@testable import AgentCore
import RestoreyCore

/// Task 15c in the runner: items apps mark as not for backup are looked for before each backup, passed to real restic
/// 0.19.1 as an exclude file that is removed however the step ends, and counted in the record. Spotlight is faked.
struct MarkedNotForBackupRunnerTests {
    /// Answers with `paths` and says each in `stillMarked` still carries the attribute.
    final class FakeIndex: MarkedItemsFinding, Sendable {
        let answer: MarkedItemsQuery
        let stillMarked: Set<String>
        let asked = Mutex(0)
        let gate = OneOutstandingGate()

        init(_ answer: MarkedItemsQuery, stillMarked: Set<String>) {
            self.answer = answer
            self.stillMarked = stillMarked
        }

        func query(scopes: [String], limit: Int) -> MarkedItemsQuery {
            asked.withLock { $0 += 1 }
            return answer
        }

        func isMarked(_ path: String) -> Bool { stillMarked.contains(path) }
    }

    /// A source with `keep/a.txt`, `cache/b.txt` and `cache/inner/c.txt`, and an index that marks `cache`,
    /// `cache/inner` and a stale `gone`.
    private static func index(for f: RunnerFixture) throws -> FakeIndex {
        for name in ["keep", "cache/inner"] {
            try FileManager.default.createDirectory(
                at: f.source.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try f.write("keep/a.txt", "a")
        try f.write("cache/b.txt", "b")
        try f.write("cache/inner/c.txt", "c")
        let cache = f.source.appendingPathComponent("cache").path
        return FakeIndex(
            .found([cache, cache + "/inner", f.source.appendingPathComponent("gone").path]),
            stillMarked: [cache, cache + "/inner"])
    }

    /// Paths in the latest snapshot, relative to the source.
    private static func latestPaths(_ f: RunnerFixture) async throws -> Set<String> {
        // Run directly: `ResticProcess` keeps only the message type of `ls`'s "node" lines.
        let invocation = makeInvocation(.check, plan: await f.plan(), context: f.context())
        let process = Process()
        process.executableURL = f.restic
        process.arguments = ["ls", "--json", "latest"]
        var environment = invocation.environment
        environment["HOME"] = f.home.path
        process.environment = environment
        let output = f.root.appendingPathComponent("ls-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        struct Node: Decodable { let path: String? }
        let prefix = f.source.path + "/"
        return Set(lines.compactMap { line -> String? in
            guard let path = (try? JSONDecoder().decode(Node.self, from: Data(line.utf8)))?.path, path.hasPrefix(prefix)
            else { return nil }
            return String(path.dropFirst(prefix.count))
        })
    }

    private static func listFiles(_ f: RunnerFixture) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: f.dependencies.notForBackupDirectory.path)) ?? []
    }

    @Test func markedItemsAreSkippedCountedAndTheirListRemoved() async throws {
        let box = Locked<FakeIndex?>(nil)
        let f = try await RunnerFixture.make(markedItems: Forward(box))
        defer { f.remove() }
        box.set(try Self.index(for: f))

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = record.outcome else {
            Issue.record("expected success, got \(record.outcome)")
            return
        }
        // `cache/inner` collapses into `cache`; the stale `gone` is dropped.
        #expect(record.markedNotForBackupSkipped == 1)
        let paths = try await Self.latestPaths(f)
        #expect(paths.contains("keep/a.txt"))
        #expect(!paths.contains("cache"))
        #expect(!paths.contains { $0.hasPrefix("cache/") })
        #expect(Self.listFiles(f).isEmpty, "the list is removed after the run")
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(log.contains("--exclude-file="))
        // The record keeps the count.
        #expect(await f.history().recent.first { $0.id == record.id }?.markedNotForBackupSkipped == 1)
    }

    @Test func aPlanThatIncludesThemAsksNothingAndRecordsNothing() async throws {
        let box = Locked<FakeIndex?>(nil)
        let f = try await RunnerFixture.make(change: { $0.skipsItemsMarkedNotForBackup = false }, markedItems: Forward(box))
        defer { f.remove() }
        let index = try Self.index(for: f)
        box.set(index)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.markedNotForBackupSkipped == nil)
        #expect(index.asked.withLock { $0 } == 0)
        #expect(try await Self.latestPaths(f).contains("cache/b.txt"))
    }

    @Test func aFailedLookBacksThemUpAndRecordsNothing() async throws {
        let f = try await RunnerFixture.make(markedItems: FakeIndex(.failed, stillMarked: []))
        defer { f.remove() }
        _ = try Self.index(for: f)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        guard case .success = record.outcome else {
            Issue.record("expected success, got \(record.outcome)")
            return
        }
        #expect(record.markedNotForBackupSkipped == nil)
        #expect(try await Self.latestPaths(f).contains("cache/b.txt"))
        #expect(f.agentInfo.value.contains { $0.contains("Gave up looking for items apps mark as not for backup") })
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(!log.contains("--exclude-file"))
    }

    @Test func aBackUpAnywayEntryIsBackedUpAndTheCountIsZero() async throws {
        let box = Locked<FakeIndex?>(nil)
        let f = try await RunnerFixture.make(markedItems: Forward(box))
        defer { f.remove() }
        let index = try Self.index(for: f)
        box.set(index)
        let cache = f.source.appendingPathComponent("cache").path
        try await f.updatePlan { $0.backUpAnyway = [cache] }

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.markedNotForBackupSkipped == 0)
        #expect(try await Self.latestPaths(f).contains("cache/inner/c.txt"))
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(!log.contains("--exclude-file"), "no flag for an empty list")
    }

    @Test func theListIsRemovedAfterAFailure() async throws {
        let box = Locked<FakeIndex?>(nil)
        let f = try await RunnerFixture.make(markedItems: Forward(box))
        defer { f.remove() }
        box.set(try Self.index(for: f))
        try "not-the-password".write(to: f.passwordFile, atomically: true, encoding: .utf8)

        let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        #expect(record.outcome == .wrongPassword)
        #expect(record.markedNotForBackupSkipped == nil)
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(log.contains("--exclude-file="), "the list was passed")
        #expect(Self.listFiles(f).isEmpty)
    }

    /// The backup is paused while restic runs (a stand-in that copies the list it was given, then sleeps): the list
    /// existed while restic ran, and is gone once the step has ended.
    @Test func theListIsRemovedAfterAnInterruption() async throws {
        let restic = try ResticBinary.require()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-marked-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let seen = scratch.appendingPathComponent("seen.txt")
        let wrapper = scratch.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then
              for arg in "$@"; do
                case "$arg" in --exclude-file=*) cp "${arg#--exclude-file=}" '\(seen.path)' ;; esac
              done
              echo '{"message_type":"status","percent_done":0.1,"total_files":1,"files_done":0,"total_bytes":1,"bytes_done":0}'
              exec /bin/sleep 30
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let box = Locked<FakeIndex?>(nil)
        let f = try await RunnerFixture.make(executable: wrapper, gracePeriod: .seconds(2), markedItems: Forward(box))
        defer { f.remove() }
        box.set(try Self.index(for: f))

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        #expect(Self.listFiles(f) == ["\(f.planID.uuidString).txt"], "the list exists while restic runs")
        _ = try await f.state.pause(f.planID)
        let record = try await run.value
        #expect(record.outcome == .paused)
        #expect(Self.listFiles(f).isEmpty)
        #expect(try String(contentsOf: seen, encoding: .utf8) == f.source.appendingPathComponent("cache").path + "\n")
        // The list's folder is this user's alone (the list itself is written 0600 by `PrivateFile`).
        let mode = try FileManager.default.attributesOfItem(atPath: f.dependencies.notForBackupDirectory.path)[.posixPermissions]
        #expect((mode as? Int) == 0o700)
    }

    /// Review I2: with Spotlight hung, the first backup's look times out (logged), later backups give up at once
    /// without another query, logged once for the episode, and nothing is recorded or skipped.
    @Test func aHungSpotlightIsLoggedOnceAndNeverQueriedAgain() async throws {
        final class Hung: MarkedItemsFinding, Sendable {
            let gate = OneOutstandingGate()
            let release = DispatchSemaphore(value: 0)
            let asked = Mutex(0)
            func query(scopes: [String], limit: Int) -> MarkedItemsQuery {
                asked.withLock { $0 += 1 }
                release.wait()
                return .found([])
            }
            func isMarked(_ path: String) -> Bool { true }
        }
        let hung = Hung()
        defer { hung.release.signal() }
        let f = try await RunnerFixture.make(markedItems: hung, markedItemsDeadline: 0.2)
        defer { f.remove() }
        try f.write("a.txt", "a")

        for _ in 0..<3 {
            let record = try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
            #expect(record.markedNotForBackupSkipped == nil)
        }
        #expect(hung.asked.withLock { $0 } == 1, "no second query while the first is outstanding")
        let lines = f.agentInfo.value
        #expect(lines.filter { $0.contains("Gave up looking for items apps mark as not for backup") }.count == 1)
        #expect(lines.filter { $0.contains("still waiting for Spotlight") }.count == 1)
    }

    @Test func aListLeftByAnAgentThatDiedIsRemovedAtTheNextStart() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let folder = f.dependencies.notForBackupDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "/x\n".write(to: folder.appendingPathComponent("\(f.planID.uuidString).txt"), atomically: true, encoding: .utf8)

        let (_, runner) = await f.reloaded()
        await runner.recoverAfterStart()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

/// Forwards to an index set after the fixture exists (its source folder is only known then).
private struct Forward: MarkedItemsFinding {
    let box: Locked<MarkedNotForBackupRunnerTests.FakeIndex?>
    let gate = OneOutstandingGate()
    init(_ box: Locked<MarkedNotForBackupRunnerTests.FakeIndex?>) { self.box = box }
    func query(scopes: [String], limit: Int) -> MarkedItemsQuery { box.value?.query(scopes: scopes, limit: limit) ?? .found([]) }
    func isMarked(_ path: String) -> Bool { box.value?.isMarked(path) ?? false }
}
