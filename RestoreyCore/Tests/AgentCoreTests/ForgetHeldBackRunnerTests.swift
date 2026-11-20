import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// v0.1.2 (TODO L95): a backup that couldn't read many more files than the last one that saved data doesn't tidy,
/// because a source that has gone missing or unreadable would otherwise make retention thin out the good snapshots.
@Suite(.timeLimit(.minutes(3)))
struct ForgetHeldBackRunnerTests {
    /// A stand-in restic whose backup reports as many unreadable files as the `count` file beside it says (none for
    /// "0", which is a success with a snapshot), and which writes every subcommand it is given to `calls`.
    private struct Stub {
        let directory: URL
        var script: URL { directory.appendingPathComponent("restic.sh") }
        var count: URL { directory.appendingPathComponent("count") }
        var calls: URL { directory.appendingPathComponent("calls") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("restorey-held-back-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #"""
                #!/bin/sh
                here=$(dirname "$0")
                echo "$1" >> "$here/calls"
                [ "$1" = cat ] && exit 10
                [ "$1" = backup ] || exit 0
                n=$(cat "$here/count")
                i=0
                while [ "$i" -lt "$n" ]; do
                    echo '{"message_type":"error","error":{"message":"open /u/f'"$i"': operation not permitted"},"during":"archival","item":"/u/f'"$i"'"}' >&2
                    i=$((i + 1))
                done
                if [ "$n" -gt 0 ]; then
                    echo '{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"dirs_new":1,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":1,"tree_blobs":1,"data_added":1,"data_added_packed":1,"total_files_processed":1,"total_bytes_processed":1,"total_duration":0.1,"backup_start":"2026-01-01T00:00:00Z","backup_end":"2026-01-01T00:00:01Z","snapshot_id":"abcd1234"}'
                    exit 3
                fi
                exit 0

                """#.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try setUnreadable(0)
        }

        func setUnreadable(_ n: Int) throws { try "\(n)".write(to: count, atomically: true, encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(at: directory) }

        /// The restic subcommands run so far, in order.
        func subcommands() -> [String] {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    private static func forgets(_ history: PlanRunHistory) -> [RunRecord] {
        history.recent.filter { $0.operation == .forget(dryRun: false) }
    }

    @Test func forgetIsSkippedWhenUnreadableJumps() async throws {
        let stub = try Stub()
        defer { stub.remove() }
        let f = try await RunnerFixture.make(executable: stub.script)
        defer { f.remove() }

        try stub.setUnreadable(3)
        let first = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(first.outcome == .warning(unreadable: 3))
        let before = stub.subcommands().count
        let forgotten = try #require(await f.history().lastForgetAt)

        try stub.setUnreadable(412)
        f.clock.advance(60)
        let second = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(second.outcome == .warning(unreadable: 412))

        // Only the backup ran after it: no forget (and so no prune), and the skip is its own record.
        #expect(Array(stub.subcommands().dropFirst(before)) == ["backup"])
        let history = await f.history()
        let held = try #require(Self.forgets(history).first)
        #expect(held.outcome == .skipped(.forgetHeldBack(unreadable: 412, previous: 3)))
        #expect(held.logFile.isEmpty)
        #expect(Self.forgets(history).count == 2, "the first backup's forget, and the skip")
        #expect(held.endedAt > forgotten)
        #expect(history.lastForgetAt == forgotten, "a skipped forget doesn't count as one that ran")
        // It is not the plan's state: a skipped tidy isn't a skipped backup.
        let status = try #require(await f.state.status().plans.first { $0.plan.id == f.planID })
        #expect(status.phase == .idle)
        #expect(status.tidyHeldBack == "Old snapshots weren’t removed: 412 files couldn’t be read, up from 3 last time.")
    }

    @Test func forgetRunsWhenTheJumpIsSmall() async throws {
        let stub = try Stub()
        defer { stub.remove() }
        let f = try await RunnerFixture.make(executable: stub.script)
        defer { f.remove() }

        try stub.setUnreadable(300)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        let before = stub.subcommands().count
        try stub.setUnreadable(450)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)

        #expect(Array(stub.subcommands().dropFirst(before)).prefix(2) == ["backup", "forget"])
        let history = await f.history()
        #expect(Self.forgets(history).allSatisfy { $0.outcome == .success(snapshotID: nil) })
        let status = try #require(await f.state.status().plans.first { $0.plan.id == f.planID })
        #expect(status.tidyHeldBack == nil)
    }

    @Test func forgetRunsOnTheFirstBackup() async throws {
        let stub = try Stub()
        defer { stub.remove() }
        let f = try await RunnerFixture.make(executable: stub.script)
        defer { f.remove() }

        try stub.setUnreadable(5000)
        let record = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(record.outcome == .warning(unreadable: 5000))
        #expect(stub.subcommands().contains("forget"))
        #expect(Self.forgets(await f.history()).allSatisfy { $0.outcome == .success(snapshotID: nil) })
    }

    /// A later tidy that runs takes the note away: the next backup compares with the one that was held back.
    @Test func theNoteGoesWhenALaterForgetRuns() async throws {
        let stub = try Stub()
        defer { stub.remove() }
        let f = try await RunnerFixture.make(executable: stub.script)
        defer { f.remove() }

        try stub.setUnreadable(3)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        try stub.setUnreadable(412)
        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(try #require(await f.state.status().plans.first).tidyHeldBack != nil)

        _ = try await f.runner.runBackup(planID: f.planID, trigger: .manual)
        #expect(try #require(await f.state.status().plans.first).tidyHeldBack == nil)
    }

    /// The rule, as a function of the two counts (`n >= 2m && n >= m + 100`; the previous backup that wasn't a warning
    /// had none).
    @Test func theRuleOnItsBoundaries() {
        func held(_ now: Int, previous: Int?) -> Bool {
            let record = previous.map { count in
                RunRecord(
                    id: UUID(), planID: UUID(), operation: .backup, trigger: .manual, startedAt: .now, endedAt: .now,
                    outcome: count == 0 ? .success(snapshotID: "a") : .warning(unreadable: count), summary: nil, logFile: "")
            }
            return PlanRunner.forgetHeldBack(after: .warning(unreadable: now), previousBackup: record) != nil
        }
        #expect(held(412, previous: 3))
        #expect(!held(450, previous: 300), "×1.5")
        #expect(held(600, previous: 300), "exactly double, and 300 more")
        #expect(held(100, previous: 0))
        #expect(!held(99, previous: 0))
        #expect(held(200, previous: 100))
        #expect(!held(199, previous: 100))
        #expect(held(150, previous: 50), "triple, and exactly 100 more")
        #expect(!held(140, previous: 50), "more than double, but fewer than 100 more")
        #expect(!held(5000, previous: nil), "no earlier backup to compare with")
        #expect(PlanRunner.forgetHeldBack(after: .success(snapshotID: "a"), previousBackup: nil) == nil)
    }

    /// The skip is kept in `state.json`: it survives encoding, in a shape an older build drops rather than chokes on.
    @Test func theSkipSurvivesTheStateFile() throws {
        let reason = SkipReason.forgetHeldBack(unreadable: 412, previous: 3)
        let data = try JSONEncoder().encode(RunOutcome.skipped(reason))
        #expect(try JSONDecoder().decode(RunOutcome.self, from: data) == .skipped(reason))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""type":"forgetHeldBack""#))
    }
}
