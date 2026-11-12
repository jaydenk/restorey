import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// Ruling R70: the 400-day run-log retention is applied by the real runner, from the scheduler's tick.
@Suite(.timeLimit(.minutes(1)))
struct RunLogPruningTests {
    /// Writes a run log under the fixture's `logs/runs/<plan>/`, last modified `daysAgo` days before the clock.
    private func oldLog(_ f: RunnerFixture, _ name: String, daysAgo: Double) throws -> URL {
        let folder = f.logs.appendingPathComponent("runs/\(f.planID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("old run\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: f.clock.now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: file.path)
        return file
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func theSchedulerTickPrunesOnceADay() async throws {
        let f = try await RunnerFixture.make(createRepository: false, confirmKit: false)
        defer { f.remove() }
        let core = SchedulerCore(
            clock: ManualClock(), now: { f.clock.now }, runner: f.runner, waitForNetwork: {})

        let first = try oldLog(f, "first.log", daysAgo: 401)
        let recent = try oldLog(f, "recent.log", daysAgo: 399)
        await core.tick()
        #expect(!exists(first))
        #expect(exists(recent))
        #expect(f.agentLog.value.contains("Removed 1 run logs older than 400 days"))

        // An hour later the prune isn't due again, so a log that has meanwhile passed 400 days stays.
        f.clock.advance(3_600)
        let second = try oldLog(f, "second.log", daysAgo: 401)
        await core.tick()
        #expect(exists(second))

        // A day after the last prune it is due.
        f.clock.advance(86_400)
        await core.tick()
        #expect(!exists(second))
    }

    @Test func aClockThatWentBackwardsMakesThePruneDue() async throws {
        let f = try await RunnerFixture.make(createRepository: false, confirmKit: false)
        defer { f.remove() }
        await f.runner.pruneRunLogsIfDue()
        f.clock.advance(-3_600)
        let file = try oldLog(f, "old.log", daysAgo: 401)
        await f.runner.pruneRunLogsIfDue()
        #expect(!exists(file))
    }
}
