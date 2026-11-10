import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// An agent being replaced starts no new restic step (Ruling R55). Once an update has replaced the
/// bundle, a restic started by the old agent runs the new helper, which the old agent refuses (its
/// signature seals an Info.plist that is no longer on disk), so every new step would fail at the
/// password. The step in flight finishes; nothing after it starts.
@Suite(.timeLimit(.minutes(3)))
struct AgentReplacementTests {
    /// restic behind a wrapper that logs every call and holds the first `backup` until released.
    struct HeldBackup {
        let directory: URL
        let wrapper: URL
        let started: URL
        let releaseFile: URL
        let callsFile: URL

        init() throws {
            let restic = try ResticBinary.require()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("restorey-held-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            wrapper = directory.appendingPathComponent("restic.sh")
            started = directory.appendingPathComponent("backup-started")
            releaseFile = directory.appendingPathComponent("release")
            callsFile = directory.appendingPathComponent("calls")
            try """
                #!/bin/sh
                echo "$*" >> '\(callsFile.path)'
                if [ "$1" = backup ] && [ ! -f '\(started.path)' ]; then
                  : > '\(started.path)'
                  while [ ! -f '\(releaseFile.path)' ]; do /bin/sleep 0.05; done
                fi
                exec '\(restic.path)' "$@"

                """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        }

        func waitUntilStarted() async throws {
            try await until { FileManager.default.fileExists(atPath: started.path) }
        }

        func release() throws {
            try "".write(to: releaseFile, atomically: true, encoding: .utf8)
        }

        /// Every restic command line, in order.
        var calls: [String] {
            ((try? String(contentsOf: callsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The restart exit and the agent log lines, as `main.swift` attaches them.
    struct ExitRecorder {
        let exits = Locked(0)
        let lines = Locked<[String]>([])

        func attach(to state: AgentState, before exit: @escaping @Sendable () -> Void = {}) async {
            let exits = exits
            let lines = lines
            await state.attach(
                restartExit: {
                    exit()
                    exits.mutate { $0 += 1 }
                },
                log: { line in lines.mutate { $0.append(line) } })
        }
    }

    static func until(
        timeout: Duration = .seconds(60), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }

    func until(_ condition: () async -> Bool) async throws { try await Self.until(condition) }

    static let refused = "Restorey is finishing the current backup before updating the agent"

    // MARK: Drains

    @Test func aDrainDuringTheBackupLetsItFinishButStartsNoMaintenance() async throws {
        let held = try HeldBackup()
        defer { held.remove() }
        let f = try await RunnerFixture.make(executable: held.wrapper)
        defer { f.remove() }
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await held.waitUntilStarted()
        let drain = Task { await f.state.prepareForRestart() }
        try await until { await f.state.isDraining }
        try held.release()

        let record = try await run.value
        guard case .success(_?) = record.outcome else {
            Issue.record("expected the backup in flight to finish with a snapshot, got \(record.outcome)")
            return
        }
        #expect(await drain.value)
        #expect(await f.pings() == [.start, .success])
        // A created plan forgets after every snapshot and checks weekly: neither ran.
        #expect(await f.operations() == [.catConfig, .initRepository, .backup])
        #expect(held.calls.map { $0.split(separator: " ").first.map(String.init) ?? "" } == ["cat", "init", "backup"])
        #expect(await f.history().activeAlerts.isEmpty)
    }

    @Test func aRunQueuedBehindAnotherPlanIsSkippedForTheUpdateAndStaysDue() async throws {
        let held = try HeldBackup()
        defer { held.remove() }
        let f = try await RunnerFixture.make(executable: held.wrapper)
        defer { f.remove() }
        try f.write("a.txt", "one")
        let queuedID = try await f.addPlanOnTheSameRepository(name: "Queued")

        let first = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await held.waitUntilStarted()
        let queued = Task { try await f.runner.runBackup(planID: queuedID, trigger: .scheduled) }
        try await until { await f.state.status().plans.first { $0.plan.id == queuedID }?.phase.isRunning == true }
        // Registered before the drain; give it time to reach the repository's queue behind the first.
        try await Task.sleep(for: .milliseconds(300))
        let drain = Task { await f.state.prepareForRestart() }
        try await until { await f.state.isDraining }
        try held.release()

        guard case .success = try await first.value.outcome else {
            Issue.record("expected the backup in flight to succeed")
            return
        }
        let skipped = try await queued.value
        #expect(skipped.outcome == .skipped(.agentUpdating))
        #expect(skipped.operation == .backup)
        #expect(skipped.logFile == "")
        #expect(await drain.value)

        // No restic for it, no ping, no alert.
        #expect(!held.calls.contains { $0.contains(queuedID.uuidString) })
        await f.runner.pingsFlushed()
        #expect(await f.checkIn.pingsByPlan[queuedID] == nil)
        #expect(await f.checkIn.pingsByPlan[f.planID] == [.start, .success])
        let (plan, history) = try await f.state.runInputs(queuedID)
        #expect(history.recent.map(\.id) == [skipped.id])
        #expect(history.activeAlerts.isEmpty)
        #expect(history.runningRecord == nil)
        #expect(history.stoppedReason == nil)

        // Due at once, for this agent's clock and for the next agent after its recovery unlock.
        #expect(nextRunDate(plan: plan, history: history, now: f.clock.now) == f.clock.now)
        f.clock.advance(60)
        let (state, runner) = await f.reloaded()
        await runner.recoverAfterStart()
        let reloaded = try await state.runInputs(queuedID)
        #expect(nextRunDate(plan: reloaded.plan, history: reloaded.history, now: f.clock.now) == f.clock.now)
    }

    // MARK: A replaced binary

    @Test func aReplacedBinaryFoundBeforeAStepBeginsARestartDrainAndExits() async throws {
        let held = try HeldBackup()
        defer { held.remove() }
        let f = try await RunnerFixture.make(executable: held.wrapper)
        defer { f.remove() }
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state)
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await held.waitUntilStarted()
        f.binaryReplaced.set(true)
        try held.release()

        guard case .success = try await run.value.outcome else {
            Issue.record("expected the backup in flight to succeed")
            return
        }
        #expect(await f.state.isDraining)
        #expect(await f.state.drainPurpose == .restart)
        #expect(await f.pings() == [.start, .success])
        #expect(await f.operations() == [.catConfig, .initRepository, .backup])
        await #expect { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) } throws: {
            ($0 as? AgentError)?.message == Self.refused
        }
        await #expect { try await f.state.backUpNow(nil) } throws: { ($0 as? AgentError)?.message == Self.refused }

        try await until { recorder.exits.value == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.exits.value == 1)
        let lines = recorder.lines.value
        #expect(lines.count == 2)
        #expect(lines.first?.contains("replaced") == true)
        #expect(lines.last?.contains("Exiting") == true)
    }

    @Test func anIdleAgentNoticesOnASchedulerTickAndExitsOnce() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state)
        let clock = f.clock
        let core = SchedulerCore(
            clock: ManualClock(), now: { clock.now }, runner: f.runner, waitForNetwork: {})
        // The plan has never backed up, so it is due; the tick must not start it.
        f.binaryReplaced.set(true)

        await core.tick()

        #expect(await core.isStopped)
        #expect(await f.state.isDraining)
        #expect(await f.state.drainPurpose == .restart)
        try await until { recorder.exits.value == 1 }
        await core.tick()
        await core.runsFinished()
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.exits.value == 1)
        #expect(await f.operations() == [.catConfig, .initRepository])
    }

    @Test func theAppsRestartDuringASelfStartedDrainIsAnsweredWhenTheStepEnds() async throws {
        let held = try HeldBackup()
        defer { held.remove() }
        let f = try await RunnerFixture.make(executable: held.wrapper)
        defer { f.remove() }
        let replied = Locked(false)
        let repliedBeforeExit = Locked<Bool?>(nil)
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state) { repliedBeforeExit.set(replied.value) }
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await held.waitUntilStarted()
        f.binaryReplaced.set(true)
        #expect(await f.runner.isWindingDown())
        #expect(await f.state.drainPurpose == .restart)

        let app = Task { await f.state.restart { _ in replied.set(true) } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!replied.value, "the backup is still running")
        #expect(recorder.exits.value == 0)

        try held.release()
        guard case .success = try await run.value.outcome else {
            Issue.record("expected the backup in flight to succeed")
            return
        }
        await app.value
        #expect(replied.value)
        try await until { recorder.exits.value == 1 }
        #expect(repliedBeforeExit.value == true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.exits.value == 1)
    }
}
