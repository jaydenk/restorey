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

    /// Calls that don't return until `answer()`, like a notification centre that has stopped answering.
    /// A post that was hanging fails when answered: its caller gave up on it long ago.
    actor HangingNotifier: AlertNotifying {
        struct Abandoned: Error {}
        private var hangAuthorisation: Bool
        private var hangPosts: Bool
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var posted: [AlertContent] = []
        private(set) var authorisationCalls = 0
        private(set) var postCalls = 0
        /// What an authorisation call that does answer says.
        var authorised: Bool? = true

        init(hangAuthorisation: Bool, hangPosts: Bool) {
            self.hangAuthorisation = hangAuthorisation
            self.hangPosts = hangPosts
        }

        func authorisationStatus() async -> Bool? {
            authorisationCalls += 1
            if hangAuthorisation { await withCheckedContinuation { waiting.append($0) } }
            return authorised
        }

        func hangAuthorisationFromNow() { hangAuthorisation = true }
        func set(authorised: Bool?) { self.authorised = authorised }

        func post(_ alert: AlertContent) async throws {
            postCalls += 1
            if hangPosts {
                await withCheckedContinuation { waiting.append($0) }
                throw Abandoned()
            }
            posted.append(alert)
        }

        var hangingCalls: Int { waiting.count }

        func answer() {
            hangAuthorisation = false
            hangPosts = false
            waiting.forEach { $0.resume() }
            waiting.removeAll()
        }
    }

    private func world(
        authorised: Bool? = true, stateStore: AgentStateTests.ControlledStore<RunState>? = nil
    ) async throws -> World {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state: AgentState
        if let stateStore {
            state = await AgentState(
                configStore: AgentState.configStore(in: dir.url), stateStore: stateStore,
                secrets: InMemorySecretStore(), credentialsDirectory: dir.url, now: clock.function)
        } else {
            state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: clock.function)
        }
        let plan = try await addPlan("Home", to: state, clock: clock)
        return World(dir: dir, clock: clock, state: state, plan: plan, notifier: FakeNotifier(authorised: authorised))
    }

    private func addPlan(
        _ name: String, to state: AgentState, clock: TestClock, checkInURL: String? = nil
    ) async throws -> Plan {
        var plan = Plan.newHotPlan(
            name: name, repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me/Documents"], exclusions: [], now: clock.now)
        plan.hasCheckInURL = checkInURL != nil
        _ = try await state.savePlan(SavePlanRequest(
            plan: plan,
            secrets: [SecretEntry(key: .repositoryPassword(plan.id), value: "pw")]
                + (checkInURL.map { [SecretEntry(key: .checkInURL(plan.id), value: $0)] } ?? [])))
        // A recent success, so `noRecentSuccess` stays out of the way.
        try await state.updateHistory(plan.id) { $0.lastSuccessAt = clock.now }
        return plan
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
    private func savedAlerts(_ world: World, plan: UUID? = nil) async throws -> [AlertCondition: AlertNotificationState] {
        let stored = try await AgentState.stateStore(in: world.dir.url).load()
        return stored?.plans[plan ?? world.plan.id]?.activeAlerts ?? [:]
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
        await fixture.state.alertsDelivered()
        #expect(await notifier.posted.count == 2)
        fixture.clock.advance(30 * 60)
        await fixture.runner.refreshStatus()
        await fixture.state.alertsDelivered()
        #expect(await notifier.posted.count == 4)
    }

    // MARK: A notification centre that doesn't answer (Ruling R44)

    /// The notifier hangs on every call. Saves, runs and the scheduler's tick carry on regardless, and
    /// delivery finishes once it answers.
    @Test(.timeLimit(.minutes(1)))
    func aHungNotifierHoldsNothingUp() async throws {
        let fixture = try await RunnerFixture.make()
        defer { fixture.remove() }
        let notifier = HangingNotifier(hangAuthorisation: true, hangPosts: true)
        await fixture.state.attach(notifier: notifier, log: { _ in }, callTimeout: .seconds(3600))
        while await notifier.hangingCalls == 0 { try await Task.sleep(for: .milliseconds(10)) }

        var renamed = await fixture.plan()
        renamed.name = "Renamed"
        let saved = try await fixture.state.savePlan(SavePlanRequest(plan: renamed, secrets: []))
        #expect(saved.plans.first?.plan.name == "Renamed")

        let core = SchedulerCore(
            clock: ContinuousClock(), now: { fixture.clock.now }, runner: fixture.runner, waitForNetwork: {})
        await core.tick()
        await core.runsFinished()
        // The backup, and the maintenance that followed it in the same run.
        let latest = try #require(await fixture.history().recent.first { $0.operation == .backup })
        guard case .success = latest.outcome else {
            Issue.record("expected the tick's backup to succeed, got \(latest.outcome)")
            return
        }

        await notifier.answer()
        #expect(await fixture.state.deliverAlerts(waitingAtMost: .seconds(10)))
    }

    @Test func aTimedOutPostIsNotCountedAndRecovers() async throws {
        let world = try await world()
        let notifier = HangingNotifier(hangAuthorisation: false, hangPosts: true)
        await world.state.attach(notifier: notifier, log: { _ in }, callTimeout: .milliseconds(200))
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        #expect(try await savedAlerts(world)[.backupFailed]?.count == 0)

        // The hung post returns (and fails: it was given up on), so the next round may post again.
        await notifier.answer()
        while await !world.state.outstandingNotifierCalls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        world.clock.advance(60)
        await world.state.deliverAlerts()
        #expect(await notifier.posted.map(\.title) == ["Backup failed — Home"])
        #expect(try await savedAlerts(world)[.backupFailed]?.count == 1)
    }

    // MARK: Unreadable settings (Ruling R45)

    @Test func unreadableSettingsPostOneAgentAlertOnTheBackOff() async throws {
        let dir = try TempDirectory()
        try Data("not json".utf8).write(to: dir.config)
        let clock = TestClock()
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: clock.function)
        let notifier = FakeNotifier(authorised: true)
        await state.attach(notifier: notifier, log: { _ in })
        await state.deliverAlerts()
        let posted = await notifier.posted
        #expect(posted.map(\.title) == ["Restorey has stopped — its settings can't be read"])
        #expect(posted.first?.identifier == "alert.agent.loadError")
        #expect(posted.first?.body.hasPrefix("config.json can't be read") == true)

        clock.advance(59 * 60)
        await state.deliverAlerts()
        #expect(await notifier.posted.count == 1)
        clock.advance(60)
        await state.deliverAlerts()
        #expect(await notifier.posted.count == 2)
        // Nothing was written: state.json can't be trusted.
        #expect(!FileManager.default.fileExists(atPath: dir.state.path))
    }

    /// With only state.json unreadable the plans are listed, stopped, but none of their alerts is posted.
    @Test func unreadableStatePostsNoPlanAlerts() async throws {
        let world = try await world()
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        try Data("not json".utf8).write(to: world.dir.state)
        let state = await AgentState(directory: world.dir.url, secrets: InMemorySecretStore(), now: world.clock.function)
        #expect(await state.status().plans.first?.alerts == [.configurationError])
        await state.attach(notifier: world.notifier, log: { _ in })
        await state.deliverAlerts()
        #expect(await world.notifier.titles == ["Restorey has stopped — its settings can't be read"])
    }

    // MARK: Check-in results (Ruling R46)

    @Test func aRejectedCheckInIsRaisedAndClearedByTheNextSuccess() async throws {
        let base = try await world()
        let plan = try await addPlan("Home", to: base.state, clock: base.clock, checkInURL: "https://hc.example/a")
        _ = try await base.state.deletePlan(base.plan.id)
        let world = World(dir: base.dir, clock: base.clock, state: base.state, plan: plan, notifier: base.notifier)
        await world.state.attach(notifier: world.notifier, log: { _ in })
        await world.state.checkInResult(planID: world.plan.id, status: 503)
        #expect(await world.state.status().plans.first?.alerts == [])

        await world.state.checkInResult(planID: world.plan.id, status: 404)
        #expect(await world.state.status().plans.first?.alerts == [.checkInRejected])
        await world.state.deliverAlerts()
        let posted = await world.notifier.posted
        #expect(posted.map(\.title) == ["Check-in URL rejected — Home"])
        #expect(posted.first?.body.contains("HTTP 404") == true)
        // A 5xx says nothing about the URL: the alert stands.
        await world.state.checkInResult(planID: world.plan.id, status: 502)
        #expect(try await savedAlerts(world)[.checkInRejected] != nil)

        await world.state.checkInResult(planID: world.plan.id, status: 200)
        await world.state.deliverAlerts()
        #expect(await world.state.status().plans.first?.alerts == [])
        #expect(try await savedAlerts(world)[.checkInRejected] == nil)
    }

    // MARK: Saving fails (Ruling R47)

    @Test func aFailedSaveStillRemembersWhatWasPosted() async throws {
        let dir = try TempDirectory()
        let store = AgentStateTests.ControlledStore(AgentState.stateStore(in: dir.url))
        let world = try await world(stateStore: store)
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await store.failEverySave()
        let lines = Locked<[String]>([])
        await world.state.attach(notifier: world.notifier, log: { line in lines.mutate { $0.append(line) } })
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.count == 1)
        #expect(lines.value.contains { $0.hasPrefix("Couldn't save") })

        world.clock.advance(60)
        await world.state.deliverAlerts()
        world.clock.advance(60)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.count == 1)
    }

    // MARK: Restarts and shared banners

    /// A new agent reads the notification state from state.json: an alert notified 10 minutes ago waits
    /// out the rest of its hour.
    @Test func aRestartMidConditionDoesNotRepostAtOnce() async throws {
        let world = try await world()
        await world.state.attach(notifier: world.notifier, log: { _ in })
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.count == 1)

        world.clock.advance(10 * 60)
        let restarted = await AgentState(directory: world.dir.url, secrets: InMemorySecretStore(), now: world.clock.function)
        let notifier = FakeNotifier(authorised: true)
        await restarted.attach(notifier: notifier, log: { _ in })
        await restarted.deliverAlerts()
        #expect(await notifier.posted.isEmpty)
        world.clock.advance(50 * 60)
        await restarted.deliverAlerts()
        #expect(await notifier.posted.count == 1)
    }

    @Test func fullDiskAccessIsOneBannerForEveryPlan() async throws {
        let world = try await world()
        let second = try await addPlan("Work", to: world.state, clock: world.clock)
        let now = world.clock.now
        for id in [world.plan.id, second.id] {
            try await world.state.updateHistory(id) {
                $0.activeAlerts[.fullDiskAccessMissing] = AlertNotificationState(raisedAt: now, lastNotifiedAt: nil, count: 0)
            }
        }
        await world.state.attach(notifier: world.notifier, log: { _ in })
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.map(\.identifier) == ["alert.agent.fullDiskAccessMissing"])
        #expect(try await savedAlerts(world)[.fullDiskAccessMissing]?.count == 1)
        #expect(try await savedAlerts(world, plan: second.id)[.fullDiskAccessMissing]?.count == 1)
    }

    // MARK: Check-in URL changes (Ruling R48)

    /// A world whose one plan has a check-in URL that the service has rejected.
    private func rejectedCheckIn() async throws -> World {
        let base = try await world()
        let plan = try await addPlan("Home", to: base.state, clock: base.clock, checkInURL: "https://hc.example/a")
        _ = try await base.state.deletePlan(base.plan.id)
        let world = World(dir: base.dir, clock: base.clock, state: base.state, plan: plan, notifier: base.notifier)
        await world.state.attach(notifier: world.notifier, log: { _ in })
        await world.state.checkInResult(planID: plan.id, status: 404)
        await world.state.deliverAlerts()
        #expect(await world.state.status().plans.first?.alerts == [.checkInRejected])
        return world
    }

    @Test func removingTheCheckInURLClearsTheRejection() async throws {
        let world = try await rejectedCheckIn()
        var plan = world.plan
        plan.hasCheckInURL = false
        _ = try await world.state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(await world.state.status().plans.first?.alerts == [])
        #expect(try await savedAlerts(world)[.checkInRejected] == nil)
        // A day later nothing is re-notified.
        world.clock.advance(25 * 3_600)
        await world.state.deliverAlerts()
        #expect(await world.notifier.posted.count == 1)
    }

    /// With no URL configured the condition is dropped even if it is still recorded.
    @Test func noCheckInURLDropsTheCondition() {
        var plan = Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/r", environmentNames: []), origin: .created,
            hostLabel: "mac", sources: ["/s"], exclusions: [], now: Date(timeIntervalSince1970: 0))
        var history = PlanRunHistory()
        history.lastSuccessAt = plan.createdAt
        history.activeAlerts[.checkInRejected] = AlertNotificationState(raisedAt: plan.createdAt, lastNotifiedAt: nil, count: 0)
        func conditions() -> Set<AlertCondition> {
            alertConditions(
                history: history, plan: plan, now: plan.createdAt, fullDiskAccessMissing: nil, notificationsAuthorised: true)
        }
        #expect(conditions().isEmpty)
        plan.hasCheckInURL = true
        #expect(conditions() == [.checkInRejected])
    }

    @Test func changingTheCheckInURLClearsTheRejectionUntilTheNext4xx() async throws {
        let world = try await rejectedCheckIn()
        // The same URL saved again changes nothing.
        _ = try await world.state.savePlan(SavePlanRequest(
            plan: world.plan, secrets: [SecretEntry(key: .checkInURL(world.plan.id), value: "https://hc.example/a")]))
        #expect(await world.state.status().plans.first?.alerts == [.checkInRejected])

        _ = try await world.state.savePlan(SavePlanRequest(
            plan: world.plan, secrets: [SecretEntry(key: .checkInURL(world.plan.id), value: "https://hc.example/b")]))
        #expect(await world.state.status().plans.first?.alerts == [])
        #expect(try await savedAlerts(world)[.checkInRejected] == nil)

        await world.state.checkInResult(planID: world.plan.id, status: 410)
        await world.state.deliverAlerts()
        #expect(await world.state.status().plans.first?.alerts == [.checkInRejected])
        let posted = await world.notifier.posted
        #expect(posted.count == 2)
        #expect(posted.last?.body.contains("HTTP 410") == true)
    }

    // MARK: Calls that stay suspended (Ruling R48)

    /// A hung authorisation call isn't made again while it is suspended, and with no answer ever given
    /// `notificationsOff` isn't raised and nothing is posted.
    @Test func aHungAuthorisationIsCalledOnceAndRaisesNothing() async throws {
        let world = try await world()
        let notifier = HangingNotifier(hangAuthorisation: true, hangPosts: false)
        await world.state.attach(notifier: notifier, log: { _ in }, callTimeout: .milliseconds(50))
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        for _ in 0..<5 {
            world.clock.advance(60)
            await world.state.deliverAlerts()
        }
        #expect(await notifier.authorisationCalls == 1)
        #expect(await notifier.postCalls == 0)
        #expect(await world.state.status().plans.first?.alerts == [.backupFailed])

        // Once it answers, the late answer is recorded and the next round posts.
        await notifier.answer()
        while await !world.state.outstandingNotifierCalls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await world.state.deliverAlerts()
        #expect(await notifier.posted.map(\.title) == ["Backup failed — Home"])
        #expect(await notifier.authorisationCalls == 2)
    }

    @Test func aTimedOutAuthorisationKeepsTheLastAnswer() async throws {
        let world = try await world()
        let notifier = HangingNotifier(hangAuthorisation: false, hangPosts: false)
        await world.state.attach(notifier: notifier, log: { _ in }, callTimeout: .milliseconds(50))
        await world.state.deliverAlerts()
        await notifier.hangAuthorisationFromNow()
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        #expect(await notifier.posted.count == 1)
        #expect(await world.state.status().plans.first?.alerts == [.backupFailed])
        await notifier.answer()
    }

    @Test func aTimedOutAuthorisationKeepsALastDenial() async throws {
        let world = try await world()
        let notifier = HangingNotifier(hangAuthorisation: false, hangPosts: false)
        await notifier.set(authorised: false)
        await world.state.attach(notifier: notifier, log: { _ in }, callTimeout: .milliseconds(50))
        await world.state.deliverAlerts()
        #expect(await world.state.status().plans.first?.alerts == [.notificationsOff])
        await notifier.hangAuthorisationFromNow()
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        await world.state.deliverAlerts()
        await world.state.deliverAlerts()
        #expect(await world.state.status().plans.first?.alerts == [.backupFailed, .notificationsOff])
        #expect(await notifier.postCalls == 0)
        await notifier.answer()
    }

    @Test func aHungPostIsNotRepeatedWhileSuspended() async throws {
        let world = try await world()
        let notifier = HangingNotifier(hangAuthorisation: false, hangPosts: true)
        await world.state.attach(notifier: notifier, log: { _ in }, callTimeout: .milliseconds(50))
        try await recordBackup(.failed(exitCode: 1, reason: "x"), in: world)
        for _ in 0..<4 {
            world.clock.advance(60)
            await world.state.deliverAlerts()
        }
        #expect(await notifier.postCalls == 1)
        #expect(try await savedAlerts(world)[.backupFailed]?.count == 0)
        await notifier.answer()
    }
}
