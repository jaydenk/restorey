import Foundation
import Synchronization
import Testing
@testable import AgentCore
import RestoreyCore

struct AgentStateTests {
    // MARK: Fixtures

    /// A fresh Application Support stand-in, removed when the test ends.
    final class TempDirectory: Sendable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("restorey-agentstate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var config: URL { url.appendingPathComponent("config.json") }
        var state: URL { url.appendingPathComponent("state.json") }
    }

    final class TestClock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
        var function: @Sendable () -> Date { { self.now } }
    }

    /// Records what happened, in order, across tasks.
    actor EventLog {
        private(set) var items: [String] = []
        func append(_ item: String) { items.append(item) }
    }

    struct FailingSecretStore: SecretStore {
        struct Failure: Error {}
        func read(_ key: SecretKey) throws -> String? { nil }
        func write(_ value: String, for key: SecretKey) throws { throw Failure() }
        func delete(_ key: SecretKey) throws {}
        func deleteAll(planID: UUID) throws {}
    }

    /// Wraps the real store so a test can make the next save fail, or hold it until released.
    actor ControlledStore<Payload: Codable & Sendable>: PayloadStore {
        struct Failure: Error {}
        private let inner: VersionedStore<Payload>
        private var holdNext = false
        private var failNext = false
        private var held: CheckedContinuation<Void, Never>?
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []

        init(_ inner: VersionedStore<Payload>) { self.inner = inner }

        func load() async throws -> Payload? { try await inner.load() }

        func save(_ payload: Payload) async throws {
            if failNext { failNext = false; throw Failure() }
            if holdNext {
                holdNext = false
                await withCheckedContinuation { continuation in
                    held = continuation
                    heldWaiters.forEach { $0.resume() }
                    heldWaiters.removeAll()
                }
            }
            try await inner.save(payload)
        }

        func holdNextSave() { holdNext = true }
        func failNextSave() { failNext = true }
        func waitUntilHeld() async {
            if held != nil { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }
        func release() { held?.resume(); held = nil }
    }

    private static func makeState(
        _ dir: TempDirectory, configStore: ControlledStore<ConfigFile>, secrets: any SecretStore,
        clock: TestClock = TestClock()
    ) async -> AgentState {
        await AgentState(
            configStore: configStore, stateStore: AgentState.stateStore(in: dir.url), secrets: secrets,
            credentialsDirectory: dir.url, now: clock.function)
    }

    private static func plan(id: UUID = UUID(), sources: [String] = ["/Users/me/Documents"], now: Date) -> Plan {
        var plan = Plan.newHotPlan(
            name: "Home",
            repository: .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "bucket", prefix: "mac")),
            origin: .created, hostLabel: "mac", sources: sources, exclusions: [], now: now)
        plan.id = id
        return plan
    }

    private static func request(_ plan: Plan, password: String = "pa ss\"wörd\n") -> SavePlanRequest {
        SavePlanRequest(plan: plan, secrets: [
            SecretEntry(key: .repositoryPassword(plan.id), value: password),
            SecretEntry(key: .s3AccessKeyID(plan.id), value: "key-id"),
            SecretEntry(key: .s3SecretAccessKey(plan.id), value: "key-secret"),
        ])
    }

    private static func makeState(
        _ dir: TempDirectory, secrets: any SecretStore = InMemorySecretStore(), clock: TestClock = TestClock()
    ) async -> AgentState {
        await AgentState(directory: dir.url, secrets: secrets, now: clock.function)
    }

    private static func message(_ error: any Error) -> String? { (error as? AgentError)?.message }

    // MARK: Saving

    @Test func savePlanPersistsAndWritesSecrets() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        let plan = Self.plan(now: clock.now)

        let status = try await state.savePlan(Self.request(plan))
        #expect(status.plans.map(\.plan) == [plan])
        #expect(try secrets.read(.repositoryPassword(plan.id)) == "pa ss\"wörd\n")
        #expect(try secrets.read(.s3AccessKeyID(plan.id)) == "key-id")
        #expect(try secrets.read(.s3SecretAccessKey(plan.id)) == "key-secret")

        // The config file holds the plan and never a secret value.
        let text = try String(contentsOf: dir.config, encoding: .utf8)
        #expect(text.contains(plan.id.uuidString))
        #expect(!text.contains("key-secret"))
        #expect(!text.contains("wörd"))

        // A second agent reading the same directory sees the plan.
        let reloaded = await Self.makeState(dir, secrets: secrets, clock: clock)
        let reloadedStatus = await reloaded.status()
        #expect(reloadedStatus.configError == nil)
        #expect(reloadedStatus.plans.map(\.plan) == [plan])

        // Saving again with the same ID replaces the plan rather than adding a second one.
        var renamed = plan
        renamed.name = "Home folder"
        let updated = try await state.savePlan(SavePlanRequest(plan: renamed, secrets: []))
        #expect(updated.plans.map(\.plan.name) == ["Home folder"])
        #expect(try secrets.read(.repositoryPassword(plan.id)) == "pa ss\"wörd\n")
    }

    @Test func applicationSupportDirectoryIsPrivate() async throws {
        let parent = try TempDirectory()
        let dir = parent.url.appendingPathComponent("com.jaydenkerr.restorey.dev", isDirectory: true)
        let state = await AgentState(directory: dir, secrets: InMemorySecretStore(), now: { Date() })
        _ = try await state.savePlan(Self.request(Self.plan(now: Date())))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func savePlanRejectsRelativeSourcePaths() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        let plan = Self.plan(sources: ["/Users/me", "Documents"], now: clock.now)

        await #expect {
            try await state.savePlan(Self.request(plan))
        } throws: { Self.message($0) == "Source folders must be absolute paths" }
        #expect(!FileManager.default.fileExists(atPath: dir.config.path))
        #expect(try secrets.read(.repositoryPassword(plan.id)) == nil)
    }

    @Test(arguments: [
        ("emptyHostLabel", "The host label can't be empty"),
        ("noSources", "Choose at least one source folder"),
        ("intervalTooShort", "Backups can't run more often than every 5 minutes"),
    ])
    func savePlanRejectsEveryValidationError(_ kind: String, _ expected: String) async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        switch kind {
        case "emptyHostLabel": plan.hostLabel = "  "
        case "noSources": plan.sources = []
        default: plan.schedule = .interval(seconds: 299)
        }
        await #expect {
            try await state.savePlan(Self.request(plan))
        } throws: { Self.message($0) == expected }
        #expect(!FileManager.default.fileExists(atPath: dir.config.path))
    }

    @Test func savePlanListsEveryProblemOnce() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(sources: ["a", "b"], now: clock.now)
        plan.hostLabel = ""
        await #expect {
            try await state.savePlan(Self.request(plan))
        } throws: {
            Self.message($0) == "The host label can't be empty. Source folders must be absolute paths"
        }
    }

    @Test func savePlanRefusesAnotherPlansSecret() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        let plan = Self.plan(now: clock.now)
        let other = UUID()
        await #expect {
            try await state.savePlan(SavePlanRequest(
                plan: plan, secrets: [SecretEntry(key: .repositoryPassword(other), value: "x")]))
        } throws: { Self.message($0) == "A secret in the request belongs to a different plan" }
        #expect(try secrets.read(.repositoryPassword(other)) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.config.path))
    }

    @Test func secretWriteFailureLeavesConfigUnchanged() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let first = Self.plan(now: clock.now)
        let writer = await Self.makeState(dir, clock: clock)
        _ = try await writer.savePlan(Self.request(first))
        let before = try Data(contentsOf: dir.config)

        let state = await Self.makeState(dir, secrets: FailingSecretStore(), clock: clock)
        await #expect(throws: AgentError.self) {
            try await state.savePlan(Self.request(Self.plan(now: clock.now)))
        }
        #expect(try Data(contentsOf: dir.config) == before)
        #expect(await state.status().plans.map(\.plan) == [first])
    }

    @Test func savePlanKeepsTheRecoveryKitConfirmation() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        // A new plan never arrives confirmed: only confirmRecoveryKit sets it.
        plan.recoveryKitConfirmedAt = clock.now
        _ = try await state.savePlan(Self.request(plan))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == nil)

        clock.advance(60)
        _ = try await state.confirmRecoveryKit(plan.id)
        let confirmedAt = clock.now
        plan.recoveryKitConfirmedAt = nil
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == confirmedAt)
        // Resending the same secrets changes nothing the user saved.
        _ = try await state.savePlan(Self.request(plan))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == confirmedAt)
    }

    @Test func repositoryChangeResetsTheRecoveryKit() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.confirmRecoveryKit(plan.id)
        plan.repository = .raw(repository: "rest:http://nas/repo", environmentNames: [])
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == nil)
    }

    @Test func passwordChangeResetsTheRecoveryKit() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.confirmRecoveryKit(plan.id)
        _ = try await state.savePlan(Self.request(plan, password: "a new password"))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == nil)
    }

    @Test func configWriteFailureRestoresTheOldSecrets() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let secrets = InMemorySecretStore()
        let store = ControlledStore(AgentState.configStore(in: dir.url))
        let state = await Self.makeState(dir, configStore: store, secrets: secrets, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan, password: "old password"))
        let configBefore = try Data(contentsOf: dir.config)

        await store.failNextSave()
        let newKey = SecretKey.environment(plan.id, name: "RESTIC_REST_PASSWORD")
        await #expect(throws: AgentError.self) {
            try await state.savePlan(SavePlanRequest(plan: plan, secrets: [
                SecretEntry(key: .repositoryPassword(plan.id), value: "new password"),
                SecretEntry(key: .s3SecretAccessKey(plan.id), value: "new key-secret"),
                SecretEntry(key: newKey, value: "added"),
            ]))
        }
        #expect(try secrets.read(.repositoryPassword(plan.id)) == "old password")
        #expect(try secrets.read(.s3SecretAccessKey(plan.id)) == "key-secret")
        #expect(try secrets.read(.s3AccessKeyID(plan.id)) == "key-id")
        #expect(try secrets.read(newKey) == nil)
        #expect(try Data(contentsOf: dir.config) == configBefore)
    }

    // MARK: Deleting

    @Test func deletePlanRemovesSecretsAndHistory() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        let doomed = Self.plan(now: clock.now)
        let kept = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(doomed))
        _ = try await state.savePlan(Self.request(kept))
        try secrets.write("FOO", for: .environment(doomed.id, name: "RESTIC_REST_PASSWORD"))
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let doomedINI = try CredentialsFile.write(planID: doomed.id, helper: helper, directory: dir.url)
        let keptINI = try CredentialsFile.write(planID: kept.id, helper: helper, directory: dir.url)
        // Pausing writes history for both plans.
        _ = try await state.pause(doomed.id)
        _ = try await state.pause(kept.id)
        #expect(try String(contentsOf: dir.state, encoding: .utf8).contains(doomed.id.uuidString))

        let status = try await state.deletePlan(doomed.id)
        #expect(status.plans.map(\.plan.id) == [kept.id])
        #expect(try secrets.read(.repositoryPassword(doomed.id)) == nil)
        #expect(try secrets.read(.s3SecretAccessKey(doomed.id)) == nil)
        #expect(try secrets.read(.environment(doomed.id, name: "RESTIC_REST_PASSWORD")) == nil)
        #expect(!FileManager.default.fileExists(atPath: doomedINI.path))
        let stateText = try String(contentsOf: dir.state, encoding: .utf8)
        #expect(!stateText.contains(doomed.id.uuidString))
        #expect(!(try String(contentsOf: dir.config, encoding: .utf8)).contains(doomed.id.uuidString))

        // The other plan is untouched.
        #expect(try secrets.read(.repositoryPassword(kept.id)) == "pa ss\"wörd\n")
        #expect(FileManager.default.fileExists(atPath: keptINI.path))
        #expect(stateText.contains(kept.id.uuidString))

        await #expect {
            try await state.deletePlan(doomed.id)
        } throws: { Self.message($0) == "There's no plan with that ID" }
    }

    @Test func deletePlanRefusesARunningPlan() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await state.beginRun(planID: plan.id)
        await #expect {
            try await state.deletePlan(plan.id)
        } throws: { Self.message($0) == "Home is backing up. Wait for it to finish, then delete it" }
        await state.endRun(planID: plan.id)
        _ = try await state.deletePlan(plan.id)
    }

    @Test func beginRunIsRefusedWhileThePlanIsBeingDeleted() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let store = ControlledStore(AgentState.configStore(in: dir.url))
        let state = await Self.makeState(dir, configStore: store, secrets: InMemorySecretStore(), clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))

        await store.holdNextSave()
        let delete = Task { try await state.deletePlan(plan.id) }
        await store.waitUntilHeld()
        // deletePlan is suspended in the config save, with the plan still in memory.
        await #expect {
            try await state.beginRun(planID: plan.id)
        } throws: { Self.message($0) == "Home is being deleted" }
        await #expect {
            try await state.deletePlan(plan.id)
        } throws: { Self.message($0) == "Home is being deleted" }
        await store.release()
        _ = try await delete.value
        await #expect {
            try await state.beginRun(planID: plan.id)
        } throws: { Self.message($0) == "There's no plan with that ID" }
        #expect(await state.status().plans.isEmpty)
    }

    // MARK: Status, pause and resume

    @Test func pauseAndResumeChangeThePhase() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        #expect(await state.status().plans.first?.phase == .idle)

        let paused = try await state.pause(plan.id)
        #expect(paused.plans.first?.phase == .paused(until: clock.now.addingTimeInterval(3600)))

        // Pause auto-resumes after an hour.
        clock.advance(3601)
        #expect(await state.status().plans.first?.phase == .idle)

        _ = try await state.pause(plan.id)
        let resumed = try await state.resume(plan.id)
        #expect(resumed.plans.first?.phase == .idle)

        await #expect {
            try await state.pause(UUID())
        } throws: { Self.message($0) == "There's no plan with that ID" }
    }

    @Test func statusReportsNextRunOnlyOnceTheRecoveryKitIsConfirmed() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let before = await state.status()
        #expect(before.generatedAt == clock.now)
        #expect(before.plans.first?.nextRunAt == nil)
        #expect(before.plans.first?.lastRecord == nil)

        let after = try await state.confirmRecoveryKit(plan.id)
        #expect(after.plans.first?.plan.recoveryKitConfirmedAt == clock.now)
        #expect(after.plans.first?.nextRunAt == clock.now)
    }

    @Test func runningPhaseCarriesProgressAndRetrying() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await state.beginRun(planID: plan.id)
        #expect(await state.status().plans.first?.phase == .running(nil, retrying: nil))
        await #expect {
            try await state.beginRun(planID: plan.id)
        } throws: { Self.message($0) == "Home is already backing up" }

        let progress = BackupStatus(percentDone: 0.4, totalFiles: 10, filesDone: 4)
        await state.updateRun(planID: plan.id, progress: progress, retrying: "retrying after 2s")
        #expect(await state.status().plans.first?.phase == .running(progress, retrying: "retrying after 2s"))
        await state.endRun(planID: plan.id)
        #expect(await state.status().plans.first?.phase == .idle)
    }

    @Test func statusPushesOnPhaseChangesAndThrottlesProgress() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let pushes = Mutex<[AgentStatus]>([])
        await state.setStatusObserver { status in pushes.withLock { $0.append(status) } }

        try await state.beginRun(planID: plan.id)                     // phase change: pushed
        for _ in 0..<5 {                                              // 5 updates in 0.4 s: one push
            await state.updateRun(planID: plan.id, progress: BackupStatus(percentDone: 0.1), retrying: nil)
            clock.advance(0.1)
        }
        clock.advance(0.5)
        await state.updateRun(planID: plan.id, progress: BackupStatus(percentDone: 0.9), retrying: nil)
        await state.endRun(planID: plan.id)                           // phase change: pushed
        _ = try await state.pause(plan.id)                            // phase change: pushed

        let phases = pushes.withLock { $0 }.map { $0.plans.first?.phase }
        #expect(phases == [
            .running(nil, retrying: nil),
            .running(BackupStatus(percentDone: 0.1), retrying: nil),
            .running(BackupStatus(percentDone: 0.9), retrying: nil),
            .idle,
            .paused(until: clock.now.addingTimeInterval(3600)),
        ])
    }

    // MARK: Config errors (Review Focus 2)

    @Test func configErrorBlocksEverything() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let plan = Self.plan(now: clock.now)
        let seeded = await Self.makeState(dir, clock: clock)
        _ = try await seeded.savePlan(Self.request(plan))
        _ = try await seeded.pause(plan.id)

        // A newer Restorey wrote config.json.
        let newer = #"{"schemaVersion": 99, "payload": {"plans": [], "somethingNew": true}}"#
        try Data(newer.utf8).write(to: dir.config)
        let configBefore = try Data(contentsOf: dir.config)
        let stateBefore = try Data(contentsOf: dir.state)

        let secrets = InMemorySecretStore()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        let status = await state.status()
        #expect(status.configError != nil)
        #expect(status.configError?.contains("newer") == true)
        #expect(status.plans.isEmpty)

        let refused = "Restorey can't change its settings until the problem with them is fixed"
        await #expect { try await state.savePlan(Self.request(plan)) } throws: { Self.message($0) == refused }
        await #expect { try await state.deletePlan(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.pause(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.resume(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.confirmRecoveryKit(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.backUpNow(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.backUpNow(nil) } throws: { Self.message($0) == refused }
        await #expect { try await state.createRepository(plan.id) } throws: { Self.message($0) == refused }
        await #expect { _ = try await state.adopt(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.beginRun(planID: plan.id) } throws: { Self.message($0) == refused }

        #expect(try Data(contentsOf: dir.config) == configBefore)
        #expect(try Data(contentsOf: dir.state) == stateBefore)
        #expect(try secrets.read(.repositoryPassword(plan.id)) == nil)
        // Draining still works, so an update can replace the agent.
        await state.prepareForRestart()
    }

    @Test func corruptStateFileIsAConfigErrorToo() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let seeded = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await seeded.savePlan(Self.request(plan))
        try Data("{not json".utf8).write(to: dir.state)
        let configBefore = try Data(contentsOf: dir.config)

        let state = await Self.makeState(dir, clock: clock)
        let status = await state.status()
        #expect(status.configError?.contains("state.json") == true)
        // The plans are still listed, each stopped with the reason.
        #expect(status.plans.map(\.plan) == [plan])
        guard case .stopped(let reason)? = status.plans.first?.phase else {
            Issue.record("expected a stopped phase, got \(String(describing: status.plans.first?.phase))")
            return
        }
        #expect(reason.contains("state.json"))
        #expect(status.plans.first?.nextRunAt == nil)
        let refused = "Restorey can't change its settings until the problem with them is fixed"
        await #expect { try await state.pause(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.savePlan(Self.request(plan)) } throws: { Self.message($0) == refused }
        await #expect { try await state.deletePlan(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.beginRun(planID: plan.id) } throws: { Self.message($0) == refused }
        #expect(try Data(contentsOf: dir.config) == configBefore)
        #expect(try Data(contentsOf: dir.state) == Data("{not json".utf8))
    }

    // MARK: Not yet available

    @Test func runActionsAreNotYetAvailable() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        await #expect(throws: AgentError.notYetAvailable) { try await state.backUpNow(plan.id) }
        await #expect(throws: AgentError.notYetAvailable) { try await state.createRepository(plan.id) }
        await #expect(throws: AgentError.notYetAvailable) { _ = try await state.adopt(plan.id) }
    }

    // MARK: Drain (Review Focus 3)

    /// Starts a run registered with `AgentState` that ends after `seconds`, logging "run ended" first.
    private static func fakeRun(
        _ state: AgentState, planID: UUID, seconds: Double, events: EventLog
    ) async throws -> Task<Void, Never> {
        try await state.beginRun(planID: planID)
        return Task {
            try? await Task.sleep(for: .seconds(seconds))
            await events.append("run ended")
            await state.endRun(planID: planID)
        }
    }

    private static func waitUntilDraining(_ state: AgentState) async throws {
        while !(await state.isDraining) { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func drainWaitsForInFlightRun() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let events = EventLog()
        let run = try await Self.fakeRun(state, planID: plan.id, seconds: 3, events: events)

        let drain = Task {
            await state.prepareForRestart()
            await events.append("drained")
        }
        try await Self.waitUntilDraining(state)

        let refused = "Restorey is finishing the current backup before updating the agent"
        await #expect { try await state.backUpNow(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.backUpNow(nil) } throws: { Self.message($0) == refused }
        await #expect { try await state.createRepository(plan.id) } throws: { Self.message($0) == refused }
        await #expect { _ = try await state.adopt(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.savePlan(Self.request(plan)) } throws: { Self.message($0) == refused }
        await #expect { try await state.deletePlan(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.confirmRecoveryKit(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.resume(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.beginRun(planID: plan.id) } throws: { Self.message($0) == refused }
        let other = Self.plan(now: clock.now)
        await #expect { try await state.beginRun(planID: other.id) } throws: { Self.message($0) == refused }
        // Pause is allowed, so the user can still stop a long first backup.
        _ = try await state.pause(plan.id)
        #expect(await events.items.isEmpty)

        await run.value
        await drain.value
        #expect(await events.items == ["run ended", "drained"])
        #expect(await state.isDraining)
        #expect(await state.status().plans.first?.phase == .paused(until: clock.now.addingTimeInterval(3600)))
        // The next agent reads the pause from disk.
        let next = await Self.makeState(dir, clock: clock)
        #expect(await next.status().plans.first?.phase == .paused(until: clock.now.addingTimeInterval(3600)))
    }

    @Test func drainWaitsForAnInFlightDeleteToFinish() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let secrets = InMemorySecretStore()
        let store = ControlledStore(AgentState.configStore(in: dir.url))
        let state = await Self.makeState(dir, configStore: store, secrets: secrets, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.pause(plan.id)   // gives the plan a history entry
        let ini = try CredentialsFile.write(
            planID: plan.id, helper: URL(fileURLWithPath: "/usr/bin/true"), directory: dir.url)

        await store.holdNextSave()
        let delete = Task { try await state.deletePlan(plan.id) }
        await store.waitUntilHeld()

        struct Leftovers: Equatable { var config, secret, credentials, history: Bool }
        let events = EventLog()
        let drain = Task { () -> Leftovers in
            await state.prepareForRestart()
            await events.append("drained")
            // What is left at the moment the drain reply would be sent.
            return Leftovers(
                config: (try? String(contentsOf: dir.config, encoding: .utf8))?.contains(plan.id.uuidString) ?? true,
                secret: (try? secrets.read(.repositoryPassword(plan.id))) != nil,
                credentials: FileManager.default.fileExists(atPath: ini.path),
                history: (try? String(contentsOf: dir.state, encoding: .utf8))?.contains(plan.id.uuidString) ?? true)
        }
        try await Self.waitUntilDraining(state)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await events.items.isEmpty)

        await store.release()
        let leftovers = await drain.value
        #expect(leftovers == Leftovers(config: false, secret: false, credentials: false, history: false))
        _ = try await delete.value
    }

    @Test func drainWithNoRunRepliesImmediately() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        let start = ContinuousClock.now
        await state.prepareForRestart()
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await state.isDraining)
        await #expect(throws: AgentError.draining) { try await state.backUpNow(nil) }
    }

    @Test(.timeLimit(.minutes(2)))
    func drainHasNoTimeoutForLongRun() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let events = EventLog()
        let start = ContinuousClock.now
        let run = try await Self.fakeRun(state, planID: plan.id, seconds: 30, events: events)

        let drain = Task {
            await state.prepareForRestart()
            await events.append("drained")
        }
        try await Self.waitUntilDraining(state)
        await run.value
        await drain.value
        #expect(await events.items == ["run ended", "drained"])
        #expect(ContinuousClock.now - start >= .seconds(30))
    }
}

extension AgentStateTests {
    /// Task 14 turns the recorded reason into "Couldn't read the backup keys from the Keychain".
    @Test func helperFailureIsRecordedPerPlanAndTakenOnce() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        let a = UUID(), b = UUID()
        await state.noteHelperFailure(planID: a, reason: "first")
        await state.noteHelperFailure(planID: a, reason: "second")
        #expect(await state.takeHelperFailure(planID: b) == nil)
        #expect(await state.takeHelperFailure(planID: a) == "second")
        #expect(await state.takeHelperFailure(planID: a) == nil)
    }
}
