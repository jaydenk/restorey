import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// An update replaces the agent's file while the old process keeps running. The app's connection then refuses that
/// process for its signature (Task 7), so the old agent must notice by itself and restart, not only when it is about to
/// start a restic step (`PlanRunner.isWindingDown`): an idle agent would otherwise never restart.
@Suite(.timeLimit(.minutes(1)))
struct ReplacementWatchTests {
    @Test func checksUntilReplacedThenActsOnce() async {
        let checks = Locked(0)
        let acted = Locked(0)
        await ReplacementWatch.run(
            every: .milliseconds(1),
            replaced: { checks.mutate { $0 += 1 }; return checks.value >= 3 },
            onReplaced: { acted.mutate { $0 += 1 } })
        #expect(checks.value == 3)
        #expect(acted.value == 1)
    }

    /// Every few seconds: soon enough that an update's "Updating…" lasts seconds, and a `stat` that cheap costs nothing.
    @Test func theIntervalIsAFewSeconds() {
        #expect(ReplacementWatch.interval == .seconds(5))
    }

    @Test func endsWithoutActingWhenCancelled() async {
        let acted = Locked(0)
        let watch = Task {
            await ReplacementWatch.run(every: .milliseconds(1), replaced: { false }, onReplaced: { acted.mutate { $0 += 1 } })
        }
        try? await Task.sleep(for: .milliseconds(20))
        watch.cancel()
        await watch.value
        #expect(acted.value == 0)
    }

    /// The whole path for an idle agent: the watch notices, the state drains (nothing in flight) and the agent exits, so
    /// launchd starts the new binary.
    @Test func anIdleAgentExitsOnceItsFileIsReplaced() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: { Date() })
        let exits = Locked(0)
        let lines = Locked<[String]>([])
        await state.attach(restartExit: { exits.mutate { $0 += 1 } }, log: { line in lines.mutate { $0.append(line) } })
        let replaced = Locked(false)
        let watch = Task {
            await ReplacementWatch.run(
                every: .milliseconds(5), replaced: { replaced.value },
                onReplaced: { await state.restartForReplacedBinary(pingBudget: .seconds(1)) })
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(exits.value == 0)
        replaced.set(true)
        await watch.value
        while exits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(exits.value == 1)
        #expect(await state.isDraining)
        #expect(lines.value.contains { $0.hasPrefix("This agent's executable was replaced by an update") })
    }
}
