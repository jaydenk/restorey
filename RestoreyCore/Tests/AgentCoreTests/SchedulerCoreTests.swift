import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The scheduler against a fake runner, a manual clock and a fake network wait. Nothing here sleeps
/// for real beyond 1 ms polls.
@Suite(.timeLimit(.minutes(1)))
struct SchedulerCoreTests {
    // MARK: Fakes

    actor FakeRunner: SchedulerRunner {
        private(set) var entries: [(plan: Plan, history: PlanRunHistory)] = []
        /// "recover", "recovered", "entries", "refresh" and "run <plan name>", in order.
        private(set) var events: [String] = []
        private(set) var starts: [(planID: UUID, trigger: RunTrigger)] = []
        private var inFlight: [UUID: Int] = [:]
        /// The most runs of any one plan that were in progress at once.
        private(set) var mostAtOnceForOnePlan = 0
        private(set) var mostAtOnce = 0
        private var errors: [UUID: any Error] = [:]
        /// When set, runs wait for it before returning.
        private var runGate: Gate?
        private var recoverGate: Gate?

        /// Reads that return these, in turn, before `entries`.
        private var queuedReads: [[(plan: Plan, history: PlanRunHistory)]] = []

        func set(_ entries: [(plan: Plan, history: PlanRunHistory)]) { self.entries = entries }
        /// The next read returns `first`; reads after it return `entries` (the plans changing between two reads).
        func set(firstRead first: [(plan: Plan, history: PlanRunHistory)], then entries: [(plan: Plan, history: PlanRunHistory)]) {
            queuedReads = [first]
            self.entries = entries
        }
        func holdRuns(_ gate: Gate?) { runGate = gate }
        func holdRecovery(_ gate: Gate?) { recoverGate = gate }
        func fail(_ planID: UUID, with error: (any Error)?) { errors[planID] = error }

        func recoverAfterStart() async {
            events.append("recover")
            await recoverGate?.wait()
            events.append("recovered")
        }

        func scheduleEntries() async -> [(plan: Plan, history: PlanRunHistory)] {
            events.append("entries")
            if !queuedReads.isEmpty { return queuedReads.removeFirst() }
            return entries
        }

        func refreshStatus() async {
            events.append("refresh")
        }

        func runBackup(planID: UUID, trigger: RunTrigger) async throws -> RunRecord {
            if let error = errors[planID] { throw error }
            let name = entries.first { $0.plan.id == planID }?.plan.name ?? "?"
            events.append("run \(name)")
            starts.append((planID, trigger))
            inFlight[planID, default: 0] += 1
            mostAtOnceForOnePlan = max(mostAtOnceForOnePlan, inFlight[planID] ?? 0)
            mostAtOnce = max(mostAtOnce, inFlight.values.reduce(0, +))
            await runGate?.wait()
            inFlight[planID, default: 1] -= 1
            let now = Date()
            return RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: trigger, startedAt: now, endedAt: now,
                outcome: .success(snapshotID: nil), summary: nil, logFile: "")
        }

        var runCount: Int { starts.count }
    }

    struct World {
        let clock = ManualClock()
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let runner = FakeRunner()
        let network = Gate()
        let logs = Locked<[String]>([])
        let core: SchedulerCore

        init() {
            let network = network
            let logs = logs
            let now = now
            core = SchedulerCore(
                clock: clock, now: { now.value }, runner: runner,
                waitForNetwork: { await network.wait() },
                log: { line in logs.mutate { $0.append(line) } })
        }
    }

    static func plan(
        _ name: String, sources: [String] = ["/Users/me/Documents"], now: Date, confirmed: Bool = true
    ) -> Plan {
        var plan = Plan.newHotPlan(
            name: name, repository: .raw(repository: "/tmp/restorey-scheduler-repo", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: sources, exclusions: [], now: now)
        if confirmed { plan.recoveryKitConfirmedAt = now }
        return plan
    }

    /// History of a plan that last tried `ago` seconds before `now`, with `latest` as its newest record.
    static func history(attempted ago: TimeInterval, before now: Date, latest: RunOutcome? = nil, planID: UUID) -> PlanRunHistory {
        var history = PlanRunHistory()
        let at = now.addingTimeInterval(-ago)
        history.lastAttemptAt = at
        if let latest {
            history.record(RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: .scheduled, startedAt: at, endedAt: at,
                outcome: latest, summary: nil, logFile: ""))
        }
        return history
    }

    // MARK: Due plans

    @Test func duePlanStartsOnTick() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])

        await w.core.tick()
        await w.core.runsFinished()

        let starts = await w.runner.starts
        #expect(starts.map(\.planID) == [plan.id])
        #expect(starts.first?.trigger == .scheduled)
    }

    @Test func notDuePlanDoesNot() async throws {
        let w = World()
        let now = w.now.value
        let recent = Self.plan("Recent", now: now)
        let unconfirmed = Self.plan("Unconfirmed", now: now, confirmed: false)
        var paused = PlanRunHistory()
        paused.pausedUntil = now.addingTimeInterval(7200)
        let pausedPlan = Self.plan("Paused", now: now)
        await w.runner.set([
            (recent, Self.history(attempted: 600, before: now, planID: recent.id)),
            (unconfirmed, PlanRunHistory()),
            (pausedPlan, paused),
        ])

        await w.core.tick()
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)

        // An hour after the last attempt it is due, and it starts as a scheduled run.
        w.now.set(now.addingTimeInterval(3000))
        await w.core.tick()
        await w.core.runsFinished()
        let starts = await w.runner.starts
        #expect(starts.map(\.planID) == [recent.id])
        #expect(starts.first?.trigger == .scheduled)
    }

    @Test func missedLockedAndPausedRunsGetTheirTriggers() async throws {
        let w = World()
        let now = w.now.value
        let missed = Self.plan("Missed", now: now)
        let locked = Self.plan("Locked", now: now)
        let resumed = Self.plan("Resumed", now: now)
        var pauseOver = Self.history(attempted: 600, before: now, planID: resumed.id)
        pauseOver.pausedUntil = now.addingTimeInterval(-1)
        await w.runner.set([
            (missed, Self.history(attempted: 3 * 3600, before: now, planID: missed.id)),
            (locked, Self.history(attempted: 16 * 60, before: now, latest: .locked, planID: locked.id)),
            (resumed, pauseOver),
        ])

        await w.core.tick()
        await w.core.runsFinished()

        let triggers = Dictionary(uniqueKeysWithValues: await w.runner.starts.map { ($0.planID, $0.trigger) })
        #expect(triggers == [missed.id: .catchUp, locked.id: .retry, resumed.id: .catchUp])
    }

    @Test func onePlanNeverRunsTwiceConcurrently() async throws {
        let w = World()
        let home = Self.plan("Home", now: w.now.value)
        let photos = Self.plan("Photos", now: w.now.value)
        await w.runner.set([(home, PlanRunHistory()), (photos, PlanRunHistory())])
        let gate = Gate()
        await w.runner.holdRuns(gate)

        // Ticks and nudges while both runs are held never return early on the runs, and never start
        // a second run of either plan.
        await w.core.tick()
        await w.core.tick()
        await w.core.nudge(reason: .manual)
        await w.core.nudge(reason: .configChanged)
        #expect(await eventually { await w.runner.runCount == 2 })
        await w.core.tick()

        // Different plans run at the same time.
        #expect(await w.runner.mostAtOnce == 2)
        #expect(await w.runner.mostAtOnceForOnePlan == 1)
        #expect(await w.runner.runCount == 2)

        gate.open()
        await w.core.runsFinished()
        #expect(await w.runner.mostAtOnceForOnePlan == 1)
    }

    // MARK: Wake

    @Test func wakeWaitsForNetworkThenTicks() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, Self.history(attempted: 2 * 3600, before: w.now.value, planID: plan.id))])

        let woke = Task { await w.core.nudge(reason: .wake) }
        // Waiting on the network, with the 120 s timeout running beside it.
        #expect(await eventually { w.network.waiterCount == 1 && w.clock.sleeperCount == 1 })
        #expect(await w.runner.runCount == 0)
        #expect(!(await w.runner.events.contains("entries")))

        w.network.open()
        await woke.value
        await w.core.runsFinished()

        let starts = await w.runner.starts
        #expect(starts.map(\.planID) == [plan.id])
        #expect(starts.first?.trigger == .catchUp)
        // The timeout was cancelled rather than left waiting.
        #expect(w.clock.sleeperCount == 0)
    }

    @Test func wakeTimesOutAfter120sAndTicks() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])

        let woke = Task { await w.core.nudge(reason: .wake) }
        #expect(await eventually { w.network.waiterCount == 1 && w.clock.sleeperCount == 1 })

        w.clock.advance(by: .seconds(119))
        // Give the scheduler the chance to (wrongly) tick before the timeout.
        for _ in 0..<20 { await Task.yield() }
        #expect(w.clock.sleeperCount == 1)
        #expect(await w.runner.runCount == 0)

        w.clock.advance(by: .seconds(1))
        await woke.value
        await w.core.runsFinished()

        #expect(await w.runner.starts.map(\.planID) == [plan.id])
        // The network wait was given up on, not left behind.
        #expect(w.network.waiterCount == 0)
    }

    @Test func ticksWaitWhileAWakeWaitsForTheNetwork() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])

        let woke = Task { await w.core.nudge(reason: .wake) }
        #expect(await eventually { w.network.waiterCount == 1 })
        // The minute's tick and other nudges start nothing before the network is back...
        await w.core.tick()
        await w.core.nudge(reason: .configChanged)
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)

        // ...and the wake's tick then runs the plan once, as a catch-up.
        w.network.open()
        await woke.value
        await w.core.runsFinished()
        let starts = await w.runner.starts
        #expect(starts.map(\.planID) == [plan.id])
        #expect(starts.first?.trigger == .catchUp)
    }

    @Test func wakeRunsAPlanJustSkippedForNoNetwork() async throws {
        let w = World()
        let now = w.now.value
        // A tick right after waking, before the wake nudge, skipped it: not due for another hour.
        let offline = Self.plan("Offline", now: now)
        let battery = Self.plan("Battery", now: now)
        await w.runner.set([
            (offline, Self.history(attempted: 5, before: now, latest: .skipped(.noNetwork), planID: offline.id)),
            (battery, Self.history(attempted: 5, before: now, latest: .skipped(.onBattery), planID: battery.id)),
        ])
        w.network.open()

        await w.core.nudge(reason: .wake)
        await w.core.runsFinished()

        let starts = await w.runner.starts
        #expect(starts.map(\.planID) == [offline.id])
        #expect(starts.first?.trigger == .catchUp)
    }

    // MARK: Mounts

    @Test func volumeMountNudgesSkippedPlan() async throws {
        let w = World()
        let now = w.now.value
        let photos = Self.plan("Photos", sources: ["/Volumes/Backup/Photos"], now: now)
        let music = Self.plan("Music", sources: ["/Volumes/Music"], now: now)
        let home = Self.plan("Home", now: now)
        await w.runner.set([
            (photos, Self.history(attempted: 60, before: now, latest: .skipped(.volumeNotMounted("Backup")), planID: photos.id)),
            (music, Self.history(attempted: 60, before: now, latest: .skipped(.volumeNotMounted("Music")), planID: music.id)),
            (home, Self.history(attempted: 60, before: now, latest: .success(snapshotID: "abc"), planID: home.id)),
        ])

        // Skipped a minute ago, so not due on a plain tick.
        await w.core.tick()
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)

        // Another volume mounting starts nothing; Backup mounting starts the plan it skipped.
        await w.core.nudge(reason: .volumeMounted("/Volumes/Other"))
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)

        await w.core.nudge(reason: .volumeMounted("/Volumes/Backup"))
        await w.core.runsFinished()
        let starts = await w.runner.starts
        #expect(starts.map(\.planID) == [photos.id])
        #expect(starts.first?.trigger == .catchUp)
    }

    @Test func aForcedPlanIsCheckedAgainstTheTicksOwnRead() async throws {
        let w = World()
        let now = w.now.value
        let photos = Self.plan("Photos", sources: ["/Volumes/Backup/Photos"], now: now)
        let skipped = Self.history(attempted: 60, before: now, latest: .skipped(.volumeNotMounted("Backup")), planID: photos.id)
        // Between the nudge's read and the tick's, a run of the plan finished and succeeded.
        let succeeded = Self.history(attempted: 1, before: now, latest: .success(snapshotID: "abc"), planID: photos.id)
        await w.runner.set(firstRead: [(photos, skipped)], then: [(photos, succeeded)])

        await w.core.nudge(reason: .volumeMounted("/Volumes/Backup"))
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)

        // The same for a wake and a no-network skip.
        let home = Self.plan("Home", now: now)
        await w.runner.set(
            firstRead: [(home, Self.history(attempted: 60, before: now, latest: .skipped(.noNetwork), planID: home.id))],
            then: [(home, Self.history(attempted: 1, before: now, latest: .success(snapshotID: "def"), planID: home.id))])
        w.network.open()
        await w.core.nudge(reason: .wake)
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)
    }

    @Test func nudgesNeverForceAPausedPlanOrOneThatMayNotRun() async throws {
        let w = World()
        let now = w.now.value
        func entry(_ plan: Plan, _ reason: SkipReason, paused: Bool = false) -> (plan: Plan, history: PlanRunHistory) {
            var history = Self.history(attempted: 60, before: now, latest: .skipped(reason), planID: plan.id)
            if paused { history.pausedUntil = now.addingTimeInterval(1800) }
            return (plan, history)
        }
        var invalid = Self.plan("Invalid", sources: ["/Volumes/Backup/c"], now: now)
        invalid.sources = []
        await w.runner.set([
            entry(Self.plan("Paused", sources: ["/Volumes/Backup/a"], now: now), .volumeNotMounted("Backup"), paused: true),
            entry(Self.plan("Unconfirmed", sources: ["/Volumes/Backup/b"], now: now, confirmed: false), .volumeNotMounted("Backup")),
            entry(invalid, .volumeNotMounted("Backup")),
            entry(Self.plan("PausedOffline", now: now), .noNetwork, paused: true),
            entry(Self.plan("UnconfirmedOffline", now: now, confirmed: false), .noNetwork),
        ])
        w.network.open()

        await w.core.nudge(reason: .volumeMounted("/Volumes/Backup"))
        await w.core.nudge(reason: .wake)
        await w.core.runsFinished()
        #expect(await w.runner.runCount == 0)
    }

    // MARK: Start-up and the loop

    @Test func recoverAfterStartRunsBeforeFirstTick() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])
        let recovery = Gate()
        await w.runner.holdRecovery(recovery)
        w.network.open()

        let loop = Task { await w.core.run() }
        #expect(await eventually { await w.runner.events == ["recover"] })
        // A nudge during recovery doesn't tick early.
        await w.core.nudge(reason: .configChanged)
        #expect(await w.runner.events == ["recover"])

        recovery.open()
        #expect(await eventually { await w.runner.runCount == 1 })
        let events = await w.runner.events
        // Nothing is read or refreshed until recovery has finished.
        #expect(Array(events.prefix(2)) == ["recover", "recovered"])
        #expect(events.dropFirst(2).contains("refresh"))
        #expect(events.contains("run Home"))
        loop.cancel()
        await loop.value
    }

    @Test func firstTickWaitsForNetwork() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])

        let loop = Task { await w.core.run() }
        // Recovered, then waiting on the network with the 120 s timeout beside it: no tick yet, and a
        // nudge meanwhile waits too.
        #expect(await eventually { w.network.waiterCount == 1 && w.clock.sleeperCount == 1 })
        await w.core.nudge(reason: .configChanged)
        #expect(await w.runner.events == ["recover", "recovered"])
        #expect(await w.runner.runCount == 0)

        w.network.open()
        #expect(await eventually { await w.runner.runCount == 1 })
        #expect(await w.runner.starts.first?.trigger == .scheduled)
        loop.cancel()
        await loop.value
    }

    @Test func firstTickRunsAfter120sWithoutNetwork() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])

        let loop = Task { await w.core.run() }
        #expect(await eventually { w.network.waiterCount == 1 && w.clock.sleeperCount == 1 })
        w.clock.advance(by: .seconds(119))
        for _ in 0..<20 { await Task.yield() }
        #expect(await w.runner.runCount == 0)

        w.clock.advance(by: .seconds(1))
        #expect(await eventually { await w.runner.runCount == 1 })
        // The network wait was given up on, and the loop is now waiting for the next minute.
        #expect(await eventually { w.network.waiterCount == 0 && w.clock.sleeperCount == 1 })
        loop.cancel()
        await loop.value
    }

    @Test func startUpRunsAPlanLastSkippedForNoNetwork() async throws {
        let w = World()
        let now = w.now.value
        let plan = Self.plan("Home", now: now)
        await w.runner.set([(plan, Self.history(attempted: 30, before: now, latest: .skipped(.noNetwork), planID: plan.id))])
        w.network.open()

        let loop = Task { await w.core.run() }
        #expect(await eventually { await w.runner.runCount == 1 })
        #expect(await w.runner.starts.first?.trigger == .catchUp)
        loop.cancel()
        await loop.value
    }

    @Test func runTicksEveryMinute() async throws {
        let w = World()
        w.network.open()
        let loop = Task { await w.core.run() }
        // One "refresh" per tick. The first tick done, the loop sleeps for a minute (the start-up
        // network timeout, cancelled at once, may be seen briefly first).
        @Sendable func ticks() async -> Int { await w.runner.events.filter { $0 == "refresh" }.count }
        #expect(await eventually { await ticks() == 1 && w.clock.sleeperCount == 1 })

        w.clock.advance(by: .seconds(59))
        for _ in 0..<20 { await Task.yield() }
        #expect(await ticks() == 1)

        w.clock.advance(by: .seconds(1))
        #expect(await eventually { await ticks() == 2 })
        #expect(await eventually { w.clock.sleeperCount == 1 })
        loop.cancel()
        await loop.value
    }

    @Test func everyTickRefreshesTheStatusFirst() async throws {
        let w = World()
        await w.core.tick()
        await w.core.tick()
        #expect(await w.runner.events == ["refresh", "entries", "refresh", "entries"])
    }

    // MARK: Errors

    @Test func drainingStopsScheduling() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])
        await w.runner.fail(plan.id, with: AgentError.draining)
        w.network.open()

        let loop = Task { await w.core.run() }
        await loop.value  // The loop ends by itself once the runner says it is draining.
        await w.core.runsFinished()
        #expect(await w.core.isStopped)

        let before = await w.runner.events
        await w.core.tick()
        await w.core.nudge(reason: .manual)
        #expect(await w.runner.events == before)
        #expect(w.logs.value.count == 1)
    }

    @Test func otherRefusalsAreLoggedOncePerPlanPerReason() async throws {
        let w = World()
        let plan = Self.plan("Home", now: w.now.value)
        await w.runner.set([(plan, PlanRunHistory())])
        await w.runner.fail(plan.id, with: AgentError.alreadyRunning(name: "Home"))

        for _ in 0..<3 {
            await w.core.tick()
            await w.core.runsFinished()
        }
        #expect(w.logs.value.count == 1)
        #expect(w.logs.value.first?.contains("Home is already backing up") == true)

        // A different reason is logged; the scheduler keeps going.
        await w.runner.fail(plan.id, with: AgentError.planDeleting(name: "Home"))
        await w.core.tick()
        await w.core.runsFinished()
        #expect(w.logs.value.count == 2)
        #expect(!(await w.core.isStopped))

        // Once a run gets through, the same refusal later is news again.
        await w.runner.fail(plan.id, with: nil)
        await w.core.tick()
        await w.core.runsFinished()
        await w.runner.fail(plan.id, with: AgentError.planDeleting(name: "Home"))
        await w.core.tick()
        await w.core.runsFinished()
        #expect(w.logs.value.count == 3)
    }
}
