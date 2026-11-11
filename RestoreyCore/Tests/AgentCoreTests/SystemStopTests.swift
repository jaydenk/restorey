import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// Ruling R67: launchd's SIGTERM (logout, restart, shutdown) is routine. `AgentState.stopForSystem` is
/// what the agent's SIGTERM handler calls; these drive it with the real restic.
@Suite(.timeLimit(.minutes(3)))
struct SystemStopTests {
    /// The restart exit and the agent log lines, as `main.swift` attaches them.
    struct ExitRecorder {
        let exits = Locked(0)
        let lines = Locked<[String]>([])

        func attach(to state: AgentState) async {
            let exits = exits
            let lines = lines
            await state.attach(
                restartExit: { exits.mutate { $0 += 1 } },
                log: { line in lines.mutate { $0.append(line) } })
        }
    }

    @Test func sigtermMidBackupStopsTheRunWithoutAVerdictAndRetriesSoon() async throws {
        let f = try await RunnerFixture.make { $0.uploadLimitKiB = 20_000 } // keeps the backup running
        defer { f.remove() }
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state)
        try await f.writeRandomFiles(count: 6, megabytes: 30)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        let started = ContinuousClock.now
        let shouldExit = await f.state.stopForSystem(runner: f.runner)
        let took = ContinuousClock.now - started
        let record = try await run.value

        #expect(shouldExit)
        #expect(took < AgentState.systemStopBudget, "the stop took \(took)")
        #expect(record.outcome == .stoppedBySystem)
        #expect(await f.pings() == [], "no /fail and no success ping")
        let history = await f.history()
        #expect(history.activeAlerts[.backupFailed] == nil)
        #expect(history.runningRecordID == nil && history.runningRecord == nil, "committed, not left to recovery")
        #expect(history.lastAttemptAt == record.startedAt)
        // restic got our SIGINT (not a SIGKILL), so it removed its own lock and said why it stopped.
        #expect(f.lockFiles().isEmpty)
        let log = try String(contentsOf: f.logs.appendingPathComponent(record.logFile), encoding: .utf8)
        #expect(log.contains("signal interrupt received"), "\(log)")
        #expect(log.contains("Finished: Stopped because the Mac was logging out, restarting or shutting down"))
        #expect(await f.operations() == [.catConfig, .initRepository, .backup], "no maintenance after the stop")
        // The short retry (R58's isShortRetry), not the plan's hour.
        #expect(isShortRetry(history))
        #expect(nextRunDate(plan: await f.plan(), history: history, now: f.clock.now)
            == record.startedAt.addingTimeInterval(15 * 60))
        #expect(SchedulerCore.trigger(plan: await f.plan(), history: history, now: f.clock.now) == .retry)
        // No new work from now on, and the restart exit was never used.
        #expect(await f.state.isDraining)
        await #expect(throws: AgentError.draining) {
            try await f.runner.runBackup(planID: f.planID, trigger: .scheduled)
        }
        #expect(recorder.exits.value == 0)

        // The next agent finds nothing to recover: no interrupted record, no alert, no ping.
        let (state, runner) = await f.reloaded()
        await runner.recoverAfterStart()
        let after = try await state.runInputs(f.planID).history
        #expect(!after.recent.contains { $0.outcome == .interrupted })
        #expect(after.activeAlerts[.backupFailed] == nil)
        await runner.pingsFlushed()
        #expect(await f.checkIn.pings == [])
    }

    /// A restic whose backup ignores SIGINT (as a hung network call would) and runs for 30 s; every
    /// other command is the real restic. The caller removes the returned directory.
    static func stubbornRestic() throws -> (directory: URL, wrapper: URL) {
        let restic = try ResticBinary.require()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-stubborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wrapper = directory.appendingPathComponent("restic.sh")
        try """
            #!/bin/sh
            if [ "$1" = backup ]; then
              trap '' INT
              echo '{"message_type":"status","percent_done":0.1,"total_files":1,"files_done":0,"total_bytes":1,"bytes_done":0}'
              exec /bin/sleep 30
            fi
            exec '\(restic.path)' "$@"

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return (directory, wrapper)
    }

    /// restic ignores SIGINT: our SIGKILL after the system-stop grace ends it, inside the budget, and
    /// it is still the system's stop (its lock is left for the next start's plain unlock).
    @Test func aResticIgnoringSIGINTIsKilledWithinTheBudget() async throws {
        let (directory, wrapper) = try Self.stubbornRestic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try await RunnerFixture.make(executable: wrapper)
        defer { f.remove() }
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        let started = ContinuousClock.now
        #expect(await f.state.stopForSystem(runner: f.runner))
        // Timed to the run's end: the stop's own wait is bounded and returns in time either way.
        let outcome = try await run.value.outcome
        let took = ContinuousClock.now - started
        #expect(took < AgentState.systemStopBudget, "the run ended \(took) after SIGTERM")
        #expect(outcome == .stoppedBySystem)
        #expect(await f.pings() == [])
    }

    /// A pause already stopping restic when SIGTERM arrives keeps its request (no second SIGINT), but
    /// its SIGKILL comes forward from the pause's 10 s grace to the system stop's, so the stop still
    /// ends inside launchd's exit timeout rather than leaving a run for recovery to call interrupted.
    @Test func aPauseInFlightIsKilledWithinTheSystemStopBudget() async throws {
        let (directory, wrapper) = try Self.stubbornRestic()
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try await RunnerFixture.make(executable: wrapper)
        defer { f.remove() }
        try f.write("a.txt", "one")

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        await f.runner.interrupt(planID: f.planID, intent: .pause)
        let started = ContinuousClock.now
        #expect(await f.state.stopForSystem(runner: f.runner))
        // The stop's own wait is bounded, so it returns in time either way; what launchd's SIGKILL
        // would cut short is the run, so time it to its end.
        let record = try await run.value
        let took = ContinuousClock.now - started
        #expect(took < AgentState.systemStopBudget, "the run ended \(took) after SIGTERM")
        #expect(record.outcome == .paused, "the pause's own non-verdict outcome")
        #expect(await f.pings() == [])
        #expect((await f.history()).runningRecordID == nil, "committed, not left to recovery")
    }

    @Test func sigtermWhileIdleExitsPromptlyAndOnlyOnce() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state)

        let started = ContinuousClock.now
        #expect(await f.state.stopForSystem(runner: f.runner))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await f.state.drainPurpose == .systemStop)
        // A second SIGTERM doesn't exit again.
        #expect(!(await f.state.stopForSystem(runner: f.runner)))
        #expect(recorder.lines.value.contains("Exiting because the system asked the agent to stop"))
    }

    /// A restart (R55/R56) that has already exited the agent: SIGTERM must not exit a second time.
    @Test func sigtermAfterARestartExitDoesNotExitAgain() async throws {
        let f = try await RunnerFixture.make()
        defer { f.remove() }
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state)
        await f.state.restartForReplacedBinary(pingBudget: .seconds(1))
        try await AgentReplacementTests.until { recorder.exits.value == 1 }

        #expect(!(await f.state.stopForSystem(runner: f.runner)))
        #expect(recorder.exits.value == 1)
    }

    /// A restart drain waiting for a long backup: SIGTERM stops the backup, the agent exits through the
    /// system stop, and the restart exit that the drain then wants never fires as well.
    @Test func sigtermDuringARestartDrainExitsOnce() async throws {
        let f = try await RunnerFixture.make { $0.uploadLimitKiB = 20_000 }
        defer { f.remove() }
        let recorder = ExitRecorder()
        await recorder.attach(to: f.state)
        try await f.writeRandomFiles(count: 6, megabytes: 30)

        let run = Task { try await f.runner.runBackup(planID: f.planID, trigger: .scheduled) }
        try await f.waitForPhase { $0.progress != nil }
        await f.state.restartForReplacedBinary(pingBudget: .seconds(1))
        #expect(await f.state.drainPurpose == .restart)

        #expect(await f.state.stopForSystem(runner: f.runner))
        #expect(try await run.value.outcome == .stoppedBySystem)
        #expect(await f.state.drainPurpose == .systemStop)
        // Give the restart drain time to see the agent idle and try its exit.
        await f.runner.pingsFlushed()
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.exits.value == 0)
        // And a re-registration drain is refused: the agent is about to exit on its own.
        await #expect(throws: AgentError.restarting) { try await f.state.prepareForReregistration(pingBudget: .seconds(1)) }
    }
}
