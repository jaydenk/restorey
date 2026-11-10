import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// The agent's alert bookkeeping end to end: conditions raised in history are posted through the
/// notifier on the back-off schedule, and the notification state is saved in `state.json`.
struct AgentStateAlertTests {
    actor FakeNotifier: AlertNotifying {
        struct Refused: Error {}
        private(set) var posted: [AlertContent] = []
        var authorised: Bool?
        var refuse = false

        init(authorised: Bool?) { self.authorised = authorised }

        func authorisationStatus() async -> Bool? { authorised }

        func post(_ alert: AlertContent) async throws {
            if refuse { throw Refused() }
            posted.append(alert)
        }

        func set(authorised: Bool?) { self.authorised = authorised }
        func set(refuse: Bool) { self.refuse = refuse }
        var titles: [String] { posted.map(\.title) }
    }

    private typealias TempDirectory = AgentStateTests.TempDirectory
    private typealias TestClock = AgentStateTests.TestClock

    private struct World {
        let dir: TempDirectory
        let clock: TestClock
        let state: AgentState
        let plan: Plan
        let notifier: FakeNotifier
    }

    private func world(authorised: Bool? = true) async throws -> World {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: clock.function)
        let plan = Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me/Documents"], exclusions: [], now: clock.now)
        _ = try await state.savePlan(SavePlanRequest(
            plan: plan, secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: "pw")]))
        // A recent success, so `noRecentSuccess` stays out of the way.
        try await state.updateHistory(plan.id) { $0.lastSuccessAt = clock.now }
        return World(dir: dir, clock: clock, state: state, plan: plan, notifier: FakeNotifier(authorised: authorised))
    }

    private func recordBackup(_ outcome: RunOutcome, in world: World) async throws {
        let now = world.clock.now
        let planID = world.plan.id
        try await world.state.updateHistory(planID) { history in
            history.record(RunRecord(
                id: UUID(), planID: planID, operation: .backup, trigger: .scheduled, startedAt: now, endedAt: now,
                outcome: outcome, summary: nil, logFile: ""))
            if case .success = outcome { history.lastSuccessAt = now }
        }
    }

    /// The alerts saved in `state.json`, read back from disk.
    private func savedAlerts(_ world: World) async throws -> [AlertCondition: AlertNotificationState] {
        let stored = try await AgentState.stateStore(in: world.dir.url).load()
        return stored?.plans[world.plan.id]?.activeAlerts ?? [:]
    }

    @Test func aRaisedAlertIsPostedAtOnceThenBacksOff() async throws {
        let world = try await world()
        await world.state.attach(notifier: world.notifier, log: { _ in })
        try await recordBackup(.failed(exitCode: 1, reason: "Fatal: unable to open repository"), in: world)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.map(\.body) == ["Fatal: unable to open repository"])
        #expect(await world.notifier.titles == ["Backup failed — Home"])
        let saved = try await savedAlerts(world)
        #expect(saved[.backupFailed]?.count == 1)
        #expect(saved[.backupFailed]?.lastNotifiedAt == world.clock.now)

        world.clock.advance(59 * 60)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.count == 1)
        world.clock.advance(60)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.count == 2)
        #expect(try await savedAlerts(world)[.backupFailed]?.count == 2)
    }

    @Test func aStatusChangeDeliversWithoutBeingAsked() async throws {
        let world = try await world()
        await world.state.attach(notifier: world.notifier, log: { _ in })
        await world.state.alertsDelivered()
        try await recordBackup(.wrongPassword, in: world)
        await world.state.alertsDelivered()
        #expect(await world.notifier.titles == ["Backup failed — Home"])
    }

    @Test func aRefusedPostIsNotCountedAndIsTriedAgain() async throws {
        let world = try await world()
        let lines = Locked<[String]>([])
        await world.notifier.set(refuse: true)
        await world.state.attach(notifier: world.notifier, log: { line in lines.mutate { $0.append(line) } })
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        let saved = try await savedAlerts(world)
        #expect(saved[.backupFailed] == AlertNotificationState(raisedAt: world.clock.now, lastNotifiedAt: nil, count: 0))
        #expect(lines.value.contains { $0.contains("backupFailed") && $0.contains(world.plan.id.uuidString) })

        await world.notifier.set(refuse: false)
        world.clock.advance(60)
        await world.state.deliverAlerts()
        #expect(await world.notifier.titles == ["Backup failed — Home"])
        #expect(try await savedAlerts(world)[.backupFailed]?.count == 1)
    }

    /// Posting without permission reports success and shows nothing (spike H3b), so nothing is posted
    /// and nothing counted: the alerts wait, and go out as soon as the agent is allowed to post.
    @Test func withoutPermissionNotificationsOffIsRaisedAndNothingIsPosted() async throws {
        let world = try await world(authorised: nil)
        await world.state.attach(notifier: world.notifier, log: { _ in })
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.isEmpty)
        let status = await world.state.status()
        #expect(status.plans.first?.alerts == [.backupFailed, .notificationsOff])
        #expect(try await savedAlerts(world)[.backupFailed]?.count == 0)

        await world.notifier.set(authorised: true)
        await world.state.deliverAlerts()
        #expect(await world.notifier.titles == ["Backup failed — Home"])
        #expect(await world.state.status().plans.first?.alerts == [.backupFailed])
        #expect(try await savedAlerts(world)[.notificationsOff] == nil)
    }

    @Test func aClearedAlertIsRemovedAndARaiseAgainNotifiesAtOnce() async throws {
        let world = try await world()
        await world.state.attach(notifier: world.notifier, log: { _ in })
        try await recordBackup(.failed(exitCode: 1, reason: "first"), in: world)
        await world.state.deliverAlerts()
        world.clock.advance(60)
        try await recordBackup(.success(snapshotID: "abc"), in: world)
        await world.state.deliverAlerts()
        #expect(try await savedAlerts(world).isEmpty)

        world.clock.advance(60)
        try await recordBackup(.failed(exitCode: 1, reason: "second"), in: world)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.map(\.body) == ["first", "second"])
    }

    @Test func withoutANotifierNothingHappens() async throws {
        let world = try await world()
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        #expect(try await savedAlerts(world).isEmpty)
    }

    // MARK: With the runner

    /// A run that finds Full Disk Access missing raises it (and the failed backup) through the runner;
    /// the status change posts both, and the scheduler's tick re-notifies an hour later.
    @Test func aRunWithoutFullDiskAccessIsPostedAndTheTickRepeatsIt() async throws {
        let fixture = try await RunnerFixture.make()
        defer { fixture.remove() }
        fixture.fda.set(.missing)
        let notifier = FakeNotifier(authorised: true)
        await fixture.state.attach(notifier: notifier, log: { _ in })
        await fixture.state.alertsDelivered()
        #expect(await notifier.posted.isEmpty)

        _ = try await fixture.runner.runBackup(planID: fixture.planID, trigger: .scheduled)
        await fixture.state.alertsDelivered()
        #expect(await notifier.titles == [
            "Backup failed — Fixture", "Full Disk Access is missing — Restorey can't read your files",
        ])

        fixture.clock.advance(30 * 60)
        await fixture.runner.refreshStatus()
        #expect(await notifier.posted.count == 2)
        fixture.clock.advance(30 * 60)
        await fixture.runner.refreshStatus()
        #expect(await notifier.posted.count == 4)
    }
}
