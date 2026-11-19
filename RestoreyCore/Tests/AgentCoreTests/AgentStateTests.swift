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
        private var failAll = false
        private var held: CheckedContinuation<Void, Never>?
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []

        init(_ inner: VersionedStore<Payload>) { self.inner = inner }

        func load() async throws -> Payload? { try await inner.load() }

        func save(_ payload: Payload) async throws {
            if failAll { throw Failure() }
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
        func failEverySave() { failAll = true }
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

    // MARK: Status ordering (final review M1)

    /// Every status carries this process's run and a sequence that only counts up, whatever the clock does.
    @Test func statusesCountUpWhileTheClockGoesBackwards() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let first = await state.status()
        clock.advance(-5 * 3600)
        let second = await state.status()
        #expect(first.agentRun != nil && first.agentRun == second.agentRun)
        #expect((second.sequence ?? 0) > (first.sequence ?? 0))
        #expect(second.generatedAt < first.generatedAt)
        #expect(second.supersedes(first))
        // A new agent process starts its own run.
        let restarted = await Self.makeState(dir, clock: clock)
        #expect(await restarted.status().agentRun != first.agentRun)
    }

    // MARK: Saving

    /// Ruling R64b: file types are stored as the plan's doc comment says, trimmed, lower case and without
    /// duplicates (the first kept, in order), so config.json holds what the backup uses.
    @Test func savePlanNormalisesFileTypes() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        var plan = Self.plan(now: Date(timeIntervalSince1970: 1_800_000_000))
        plan.fileTypeExclusions = [" VMDK ", "vmdk", "Iso"]
        let status = try await state.savePlan(Self.request(plan))
        #expect(status.plans.first?.plan.fileTypeExclusions == ["vmdk", "iso"])
        let stored = try #require(try await AgentState.configStore(in: dir.url).load())
        #expect(stored.plans.first?.fileTypeExclusions == ["vmdk", "iso"])
    }

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
        ("emptyHostLabel", "The host label can’t be empty"),
        ("noSources", "Choose at least one source folder"),
        ("intervalTooShort", "Backups can’t run more often than every 5 minutes"),
        ("uploadLimitZero", "The upload limit must be more than 0 KiB/s"),
        ("uploadLimitNegative", "The upload limit must be more than 0 KiB/s"),
    ])
    func savePlanRejectsEveryValidationError(_ kind: String, _ expected: String) async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        switch kind {
        case "emptyHostLabel": plan.hostLabel = "  "
        case "noSources": plan.sources = []
        case "uploadLimitZero": plan.uploadLimitKiB = 0
        case "uploadLimitNegative": plan.uploadLimitKiB = -5
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
            Self.message($0) == "The host label can’t be empty. Source folders must be absolute paths"
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

    /// The kit's restore commands name the host label (`restic restore latest --host <label>`), so a kit saved
    /// before a new label would restore the old group's latest snapshot: a new label needs a new kit.
    @Test func hostLabelChangeResetsTheRecoveryKit() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.confirmRecoveryKit(plan.id)
        plan.name = "Renamed"
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt != nil)
        plan.hostLabel = "studio"
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == nil)
    }

    /// The check-in URL isn't needed to open or restore the repository (product spec §7's kit is the address, the
    /// password, the backend keys, the host label and the commands), so adding, changing or removing it from the
    /// Schedule tab's Alerts section doesn't pause backups for a new kit. Answering "No off-Mac monitoring — Add…" mustn't stop them.
    @Test func checkInURLChangeKeepsTheRecoveryKit() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.confirmRecoveryKit(plan.id)
        let confirmedAt = clock.now

        plan.hasCheckInURL = true
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: [
            SecretEntry(key: .checkInURL(plan.id), value: "https://hc-ping.com/first"),
        ]))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == confirmedAt)
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: [
            SecretEntry(key: .checkInURL(plan.id), value: "https://hc-ping.com/second"),
        ]))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == confirmedAt)
        plan.hasCheckInURL = false
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == confirmedAt)

        // A key changed alongside it still needs a new kit.
        plan.hasCheckInURL = true
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: [
            SecretEntry(key: .checkInURL(plan.id), value: "https://hc-ping.com/third"),
            SecretEntry(key: .s3SecretAccessKey(plan.id), value: "rotated"),
        ]))
        #expect(await state.status().plans.first?.plan.recoveryKitConfirmedAt == nil)
    }

    // MARK: Setup state (Ruling P2-3, Review Focus 2)

    @Test func firstKitConfirmationSetsSetupCompleted() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        // The agent owns it: a client can't send a plan that has already finished setup.
        plan.setupCompletedAt = clock.now
        _ = try await state.savePlan(Self.request(plan))
        var status = try #require(await state.status().plans.first)
        #expect(status.setupState == .unfinished)
        #expect(status.plan.setupCompletedAt == nil)

        clock.advance(60)
        status = try #require(try await state.confirmRecoveryKit(plan.id).plans.first)
        let completedAt = clock.now
        #expect(status.setupState == .complete)
        #expect(status.plan.setupCompletedAt == completedAt)

        // A changed secret means a new recovery kit, but setup stays finished.
        clock.advance(60)
        plan.setupCompletedAt = nil
        status = try #require(try await state.savePlan(Self.request(plan, password: "a new password")).plans.first)
        #expect(status.setupState == .needsNewKit)
        #expect(status.plan.setupCompletedAt == completedAt)

        // Confirming the new kit doesn't move when setup finished.
        clock.advance(60)
        status = try #require(try await state.confirmRecoveryKit(plan.id).plans.first)
        #expect(status.setupState == .complete)
        #expect(status.plan.setupCompletedAt == completedAt)
        // And it survives a reload from disk.
        let reloaded = await Self.makeState(dir, clock: clock)
        #expect(await reloaded.status().plans.first?.plan.setupCompletedAt == completedAt)
    }

    // MARK: The screens' calls: history, recovery kit, off-Mac note

    /// Every plan's records in one list, newest first. A last backup that has fallen out of `recent` is
    /// still listed, and one that is still in `recent` is listed once.
    @Test func historyMergesPlansNewestFirst() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let first = Self.plan(now: clock.now)
        let second = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(first))
        _ = try await state.savePlan(Self.request(second))

        func record(_ plan: Plan, _ outcome: RunOutcome, minutesAgo: Double) -> RunRecord {
            let start = clock.now.addingTimeInterval(-minutesAgo * 60)
            return RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled, startedAt: start,
                endedAt: start.addingTimeInterval(30), outcome: outcome, summary: nil, logFile: "")
        }
        // The first plan: a success, then a full `recent` of skips (250 to 201 minutes ago) that pushes it out.
        let success = record(first, .success(snapshotID: "abc"), minutesAgo: 300)
        let skips = (0..<PlanRunHistory.recentLimit).map {
            record(first, .skipped(.onBattery), minutesAgo: 250 - Double($0))
        }
        _ = try await state.updateHistory(first.id) { history in
            history.record(success)
            for skip in skips { history.record(skip) }
        }
        #expect(try await state.runInputs(first.id).history.recent.contains(success) == false)
        // The second plan: its last backup is still in `recent`, between the first plan's skips.
        let unchanged = record(second, .unchanged, minutesAgo: 225.5)
        let failed = record(second, .failed(exitCode: 1, reason: "boom"), minutesAgo: 100)
        _ = try await state.updateHistory(second.id) { history in
            history.record(unchanged)
            history.record(failed)
        }

        let newestSkips = Array(skips[25...].reversed()) // 201 to 225 minutes ago
        let olderSkips = Array(skips[..<25].reversed()) // 226 to 250 minutes ago
        #expect(try await state.history(nil) == [failed] + newestSkips + [unchanged] + olderSkips + [success])
        #expect(try await state.history(first.id) == skips.reversed() + [success])
        #expect(try await state.history(second.id) == [failed, unchanged])
        await #expect { try await state.history(UUID()) } throws: { ($0 as? AgentError) == .unknownPlan }
    }

    /// The kit holds every stored secret: an S3 plan's password, both keys and its check-in URL; a raw
    /// plan's password and each environment value, in the plan's order.
    @Test func recoveryKitReturnsAllSecrets() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        var s3 = Self.plan(now: clock.now)
        s3.hasCheckInURL = true
        var request = Self.request(s3)
        let checkIn = SecretEntry(key: .checkInURL(s3.id), value: "https://hc-ping.com/not-a-real-uuid")
        request.secrets.append(checkIn)
        _ = try await state.savePlan(request)

        let s3Kit = try await state.recoveryKit(s3.id)
        #expect(s3Kit.plan == s3)
        #expect(s3Kit.secrets == request.secrets)

        let raw = Plan.newHotPlan(
            name: "NAS",
            repository: .raw(repository: "rest:https://nas.local:8000/mac",
                             environmentNames: ["RESTIC_REST_USERNAME", "RESTIC_REST_PASSWORD"]),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: clock.now)
        let rawSecrets = [
            SecretEntry(key: .repositoryPassword(raw.id), value: "raw password"),
            SecretEntry(key: .environment(raw.id, name: "RESTIC_REST_USERNAME"), value: "me"),
            SecretEntry(key: .environment(raw.id, name: "RESTIC_REST_PASSWORD"), value: "rest secret"),
        ]
        // Saved in another order: the kit follows the plan's environment names.
        _ = try await state.savePlan(SavePlanRequest(plan: raw, secrets: rawSecrets.reversed()))
        let rawKit = try await state.recoveryKit(raw.id)
        #expect(rawKit.plan == raw)
        #expect(rawKit.secrets == rawSecrets)

        // A kit missing a secret would be useless in a disaster: refused, naming the account only.
        try secrets.delete(.environment(raw.id, name: "RESTIC_REST_PASSWORD"))
        await #expect { _ = try await state.recoveryKit(raw.id) } throws: { error in
            let text = Self.message(error) ?? ""
            return text.contains("environment.RESTIC_REST_PASSWORD") && !text.contains("rest secret")
        }
    }

    @Test func recoveryKitRefusedForUnknownPlan() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        _ = try await state.savePlan(Self.request(Self.plan(now: Date(timeIntervalSince1970: 1_800_000_000))))
        await #expect { _ = try await state.recoveryKit(UUID()) } throws: { ($0 as? AgentError) == .unknownPlan }
    }

    /// The agent owns `offMacNoteDismissed`: only `dismissOffMacNote` sets it, and a saved plan can't
    /// clear it (or set it on a new plan).
    @Test func dismissOffMacNotePersists() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        plan.offMacNoteDismissed = true
        _ = try await state.savePlan(Self.request(plan))
        #expect(await state.status().plans.first?.plan.offMacNoteDismissed == false)

        let status = try await state.dismissOffMacNote(plan.id)
        #expect(status.plans.first?.plan.offMacNoteDismissed == true)

        plan.offMacNoteDismissed = false
        let resaved = try await state.savePlan(Self.request(plan))
        #expect(resaved.plans.first?.plan.offMacNoteDismissed == true)

        let reloaded = await Self.makeState(dir, clock: clock)
        #expect(await reloaded.status().plans.first?.plan.offMacNoteDismissed == true)
        await #expect { _ = try await state.dismissOffMacNote(UUID()) } throws: { ($0 as? AgentError) == .unknownPlan }
    }

    @Test func lastBackupSkipsMaintenanceRecords() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        #expect(await state.status().plans.first?.lastBackup == nil)

        func record(_ operation: ResticOperation, _ outcome: RunOutcome, minutesAgo: Double) -> RunRecord {
            let start = clock.now.addingTimeInterval(-minutesAgo * 60)
            return RunRecord(
                id: UUID(), planID: plan.id, operation: operation, trigger: .scheduled, startedAt: start,
                endedAt: start.addingTimeInterval(30), outcome: outcome, summary: nil, logFile: "")
        }
        let failed = record(.backup, .failed(exitCode: 1, reason: "boom"), minutesAgo: 40)
        let unchanged = record(.backup, .unchanged, minutesAgo: 30)
        let skipped = record(.backup, .skipped(.onBattery), minutesAgo: 20)
        let forget = record(.forget(dryRun: false), .success(snapshotID: nil), minutesAgo: 10)
        let size = RepositorySize(bytes: 12_345_678_901, measuredAt: clock.now.addingTimeInterval(-600))
        let status = try await state.updateHistory(plan.id) { history in
            // Oldest first, so `recent` reads newest first: forget, skipped, unchanged, failed.
            for item in [failed, unchanged, skipped, forget] { history.record(item) }
            history.repositorySize = size
        }
        let planStatus = try #require(status.plans.first)
        #expect(planStatus.lastRecord == forget)
        #expect(planStatus.lastBackup == unchanged)
        #expect(planStatus.repositorySize == size)

        // A warning counts as backed up; a newer failure or pause doesn't replace it.
        let warning = record(.backup, .warning(unreadable: 2), minutesAgo: 5)
        let paused = record(.backup, .paused, minutesAgo: 1)
        let after = try await state.updateHistory(plan.id) { history in
            history.record(warning)
            history.record(paused)
        }
        #expect(after.plans.first?.lastBackup == warning)

        // A weekend of hourly skips, more than `recent` holds, leaves it in place.
        let skips = (0...PlanRunHistory.recentLimit).map {
            record(.backup, .skipped(.volumeNotMounted("Backup")), minutesAgo: -Double($0) * 60)
        }
        let weekend = try await state.updateHistory(plan.id) { history in
            for skip in skips { history.record(skip) }
        }
        #expect(weekend.plans.first?.lastRecord?.outcome == .skipped(.volumeNotMounted("Backup")))
        #expect(weekend.plans.first?.lastBackup == warning)
    }

    @Test func statusCarriesTheNetworkSettings() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        #expect(await state.status().network == .defaults)
    }

    // MARK: Network settings (Ruling P2-6)

    @Test func saveNetworkSettingsPersistsAndPushes() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        let pushes = Mutex<[AgentStatus]>([])
        await state.setStatusObserver { status in pushes.withLock { $0.append(status) } }
        let settings = NetworkSettings(uploadLimitKiB: 750, skipOnConstrainedNetwork: false, skippedWiFiNames: [" Café ", "Home"])

        let status = try await state.saveNetworkSettings(settings)

        let saved = NetworkSettings(uploadLimitKiB: 750, skipOnConstrainedNetwork: false, skippedWiFiNames: ["Café", "Home"])
        #expect(status.network == saved, "names are trimmed")
        #expect(await state.networkSettings == saved)
        #expect(pushes.withLock { $0 }.map(\.network) == [saved])
        let reloaded = await Self.makeState(dir)
        #expect(await reloaded.status().network == saved)
    }

    @Test(arguments: [
        (NetworkSettings(uploadLimitKiB: 0, skipOnConstrainedNetwork: true, skippedWiFiNames: []),
         "The upload limit must be more than 0 KiB/s"),
        (NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: true, skippedWiFiNames: ["  "]),
         "A Wi-Fi network name can’t be empty"),
        (NetworkSettings(uploadLimitKiB: -5, skipOnConstrainedNetwork: true, skippedWiFiNames: ["Home", "home"]),
         "The upload limit must be more than 0 KiB/s. The Wi-Fi network “home” is in the list more than once"),
    ])
    func saveNetworkSettingsRefusesInvalidSettings(settings: NetworkSettings, sentence: String) async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        let pushes = Mutex(0)
        await state.setStatusObserver { _ in pushes.withLock { $0 += 1 } }

        await #expect { try await state.saveNetworkSettings(settings) } throws: { Self.message($0) == sentence }
        #expect(await state.networkSettings == .defaults)
        #expect(!FileManager.default.fileExists(atPath: dir.config.path), "nothing written")
        #expect(pushes.withLock { $0 } == 0)
    }

    @Test func saveNetworkSettingsKeepsThePlans() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.confirmRecoveryKit(plan.id)
        let before = await state.status().plans.map(\.plan)

        let status = try await state.saveNetworkSettings(
            NetworkSettings(uploadLimitKiB: 100, skipOnConstrainedNetwork: true, skippedWiFiNames: []))
        #expect(status.plans.map(\.plan) == before)
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
        _ = try await state.pause(doomed.id, for: .oneHour)
        _ = try await state.pause(kept.id, for: .oneHour)
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
        } throws: { Self.message($0) == "There’s no plan with that ID" }
    }

    /// The plan's run logs go with it, not 400 days later; other plans' logs stay.
    @Test func deletePlanRemovesRunLogs() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let runLogs = RunLogStore(root: dir.url.appendingPathComponent("logs"), subsystem: "test.restorey")
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), runLogs: runLogs, now: clock.function)
        let doomed = Self.plan(now: clock.now)
        let kept = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(doomed))
        _ = try await state.savePlan(Self.request(kept))
        let runs = dir.url.appendingPathComponent("logs/runs")
        for plan in [doomed, kept] {
            try await runLogs.begin(planID: plan.id, operation: .backup, startedAt: clock.now, redactor: Redactor(secrets: [])).close()
        }

        _ = try await state.deletePlan(doomed.id)
        #expect(!FileManager.default.fileExists(atPath: runs.appendingPathComponent(doomed.id.uuidString).path))
        #expect(FileManager.default.fileExists(atPath: runs.appendingPathComponent(kept.id.uuidString).path))
    }

    /// Logs that can't be removed don't stop the rest of the clean-up, and the reply says what was left.
    @Test func deletePlanReportsRunLogsItCouldNotRemove() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let runLogs = RunLogStore(root: dir.url.appendingPathComponent("logs"), subsystem: "test.restorey")
        let secrets = InMemorySecretStore()
        let state = await AgentState(directory: dir.url, secrets: secrets, runLogs: runLogs, now: clock.function)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await runLogs.begin(planID: plan.id, operation: .backup, startedAt: clock.now, redactor: Redactor(secrets: [])).close()
        let planLogs = dir.url.appendingPathComponent("logs/runs/\(plan.id.uuidString)")
        // A read-only plan folder: its log file can't be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: planLogs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: planLogs.path) }

        await #expect {
            try await state.deletePlan(plan.id)
        } throws: { Self.message($0)?.hasPrefix("Home was deleted, but Restorey couldn’t remove its run logs") == true }
        #expect(await state.status().plans.isEmpty)
        #expect(try secrets.read(.repositoryPassword(plan.id)) == nil)
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
        } throws: { Self.message($0) == "There’s no plan with that ID" }
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

        let paused = try await state.pause(plan.id, for: .oneHour)
        #expect(paused.plans.first?.phase == .paused(until: clock.now.addingTimeInterval(3600)))

        // Pause auto-resumes after an hour.
        clock.advance(3601)
        #expect(await state.status().plans.first?.phase == .idle)

        // Resume on a paused plan starts a backup through Back Up Now (PlanRunnerTests); with no runner
        // attached that is refused, and the pause has been cleared first.
        _ = try await state.pause(plan.id, for: .oneHour)
        await #expect(throws: AgentError.runnerUnavailable) { try await state.resume(plan.id) }
        #expect(await state.status().plans.first?.phase == .idle)
        // Resume on a plan that isn't paused starts nothing.
        let resumed = try await state.resume(plan.id)
        #expect(resumed.plans.first?.phase == .idle)

        await #expect {
            try await state.pause(UUID(), for: .oneHour)
        } throws: { Self.message($0) == "There’s no plan with that ID" }
    }

    @Test func eachLengthPausesForItsTime() async throws {
        for length in PauseLength.allCases {
            let dir = try TempDirectory()
            let clock = TestClock()
            let state = await Self.makeState(dir, clock: clock)
            let plan = Self.plan(now: clock.now)
            _ = try await state.savePlan(Self.request(plan))
            _ = try await state.pause(plan.id, for: length)
            #expect(try await state.runInputs(plan.id).history.pausedUntil == clock.now.addingTimeInterval(length.seconds))
        }
    }

    @Test func aFourHourPauseIsKeptAcrossAnAgentRestart() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let until = clock.now.addingTimeInterval(14400)
        _ = try await state.pause(plan.id, for: .fourHours)

        let reloaded = await Self.makeState(dir, clock: clock)
        #expect(await reloaded.status().plans.first?.phase == .paused(until: until))
        await reloaded.clampStretchedPauses()
        #expect(try await reloaded.runInputs(plan.id).history.pausedUntil == until)
    }

    /// Review focus 3: the tick cuts a pause the clock stretched back to a day from now.
    @Test func aPauseIsNeverLongerThanADayEvenIfTheClockWentBack() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await state.updateHistory(plan.id) { $0.pausedUntil = clock.now.addingTimeInterval(3 * 86400) }
        #expect(await state.status().plans.first?.phase == .paused(until: clock.now.addingTimeInterval(86400)))
        await state.clampStretchedPauses()
        #expect(try await state.runInputs(plan.id).history.pausedUntil == clock.now.addingTimeInterval(86400))
    }

    /// Review focus 5: a request from another build, or a malformed one, is refused with a sentence and pauses nothing.
    @Test func anUnknownPauseLengthIsRefused() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))

        let unknown = Data(#"{"planID":"\#(plan.id.uuidString)","length":"oneWeek"}"#.utf8)
        let refusal = "Restorey can’t pause for that long. Choose 1 hour, 4 hours or until tomorrow."
        #expect { try PauseRequest.decoded(from: unknown) } throws: { Self.message($0) == refusal }
        #expect(try await state.runInputs(plan.id).history.pausedUntil == nil)
        #expect(await state.status().plans.first?.phase == .idle)

        // Any other fault keeps the generic reading error, and a known request decodes.
        let malformed = Data(#"{"planID":"nope"}"#.utf8)
        #expect { try PauseRequest.decoded(from: malformed) } throws: {
            Self.message($0)?.hasPrefix("Restorey couldn’t read the request") == true
        }
        let known = Data(#"{"planID":"\#(plan.id.uuidString)","length":"fourHours"}"#.utf8)
        #expect(try PauseRequest.decoded(from: known) == PauseRequest(planID: plan.id, length: .fourHours))
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
        _ = try await state.pause(plan.id, for: .oneHour)                            // phase change: pushed

        let phases = pushes.withLock { $0 }.map { $0.plans.first?.phase }
        #expect(phases == [
            .running(nil, retrying: nil),
            .running(BackupStatus(percentDone: 0.1), retrying: nil),
            .running(BackupStatus(percentDone: 0.9), retrying: nil),
            .idle,
            .paused(until: clock.now.addingTimeInterval(3600)),
        ])
    }

    @Test func timeBasedChangesArePushedWhenTheSchedulerRefreshes() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.confirmRecoveryKit(plan.id)
        _ = try await state.pause(plan.id, for: .oneHour)
        let pushes = Mutex<[AgentStatus]>([])
        await state.setStatusObserver { status in pushes.withLock { $0.append(status) } }

        // Nothing has changed since the last push.
        await state.pushStatusIfChanged()
        clock.advance(60)
        await state.pushStatusIfChanged()
        #expect(pushes.withLock { $0 }.isEmpty)

        // The pause runs out with no call at all: the next refresh pushes the plan idle and due.
        clock.advance(3600)
        await state.pushStatusIfChanged()
        await state.pushStatusIfChanged()
        let pushed = pushes.withLock { $0 }
        #expect(pushed.count == 1)
        #expect(pushed.first?.plans.first?.phase == .idle)
        #expect(pushed.first?.plans.first?.nextRunAt == clock.now)
    }

    // MARK: Config errors (Review Focus 2)

    @Test func configErrorBlocksEverything() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let plan = Self.plan(now: clock.now)
        let seeded = await Self.makeState(dir, clock: clock)
        _ = try await seeded.savePlan(Self.request(plan))
        _ = try await seeded.pause(plan.id, for: .oneHour)

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
        #expect(status.network == nil, "config.json couldn’t be read")

        let refused = "Restorey can’t change its settings until the problem with them is fixed"
        await #expect { try await state.savePlan(Self.request(plan)) } throws: { Self.message($0) == refused }
        await #expect { try await state.deletePlan(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.pause(plan.id, for: .oneHour) } throws: { Self.message($0) == refused }
        await #expect { try await state.cancel(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.resume(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.confirmRecoveryKit(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.backUpNow(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.backUpNow(nil) } throws: { Self.message($0) == refused }
        await #expect { try await state.createRepository(plan.id) } throws: { Self.message($0) == refused }
        await #expect { _ = try await state.adopt(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.beginRun(planID: plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.saveNetworkSettings(.defaults) } throws: { Self.message($0) == refused }
        await #expect { _ = try await state.probeRepository(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.dismissOffMacNote(plan.id) } throws: { Self.message($0) == refused }
        // Reads too: without the files there is no plan to answer for.
        await #expect { _ = try await state.history(nil) } throws: { Self.message($0) == refused }
        await #expect { _ = try await state.recoveryKit(plan.id) } throws: { Self.message($0) == refused }

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
        #expect(status.network == .defaults, "config.json was read")
        guard case .stopped(let reason)? = status.plans.first?.phase else {
            Issue.record("expected a stopped phase, got \(String(describing: status.plans.first?.phase))")
            return
        }
        #expect(reason.contains("state.json"))
        #expect(status.plans.first?.nextRunAt == nil)
        let refused = "Restorey can’t change its settings until the problem with them is fixed"
        await #expect { try await state.pause(plan.id, for: .oneHour) } throws: { Self.message($0) == refused }
        await #expect { try await state.savePlan(Self.request(plan)) } throws: { Self.message($0) == refused }
        await #expect { try await state.deletePlan(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.beginRun(planID: plan.id) } throws: { Self.message($0) == refused }
        #expect(try Data(contentsOf: dir.config) == configBefore)
        #expect(try Data(contentsOf: dir.state) == Data("{not json".utf8))
    }

    // MARK: Stops (Ruling R34)

    private static func stop(_ state: AgentState, _ id: UUID) async throws {
        try await state.updateHistory(id) { history in
            history.stoppedReason = "The repository password is wrong"
            history.activeAlerts[.configurationError] = AlertNotificationState(
                raisedAt: Date(timeIntervalSince1970: 1_800_000_000), lastNotifiedAt: nil, count: 0)
        }
    }

    @Test func changingThePasswordClearsAStop() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await Self.stop(state, plan.id)

        let status = try await state.savePlan(Self.request(plan, password: "the right one"))
        let entry = try #require(status.plans.first)
        #expect(entry.phase == .idle)
        #expect(!entry.alerts.contains(.configurationError))
        let history = try await state.runInputs(plan.id).history
        #expect(history.stoppedReason == nil)
        #expect(history.activeAlerts[.configurationError] == nil)

        // And it is saved: a restarted agent sees the plan unstopped.
        let reloaded = await Self.makeState(dir, clock: clock)
        #expect(try await reloaded.runInputs(plan.id).history.stoppedReason == nil)
    }

    @Test func anUnchangedResaveOrResumeKeepsTheStop() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await Self.stop(state, plan.id)

        plan.name = "Renamed"
        _ = try await state.savePlan(Self.request(plan))
        _ = try await state.resume(plan.id)
        let history = try await state.runInputs(plan.id).history
        #expect(history.stoppedReason == "The repository password is wrong")
        #expect(history.activeAlerts[.configurationError] != nil)
    }

    /// A new host label needs a new kit (Ruling R3) but cures nothing a stop is about: the stop stays.
    @Test func aHostLabelChangeKeepsAStop() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        var plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await Self.stop(state, plan.id)

        plan.hostLabel = "studio"
        _ = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        let history = try await state.runInputs(plan.id).history
        #expect(history.stoppedReason == "The repository password is wrong")
        #expect(history.activeAlerts[.configurationError] != nil)
    }

    /// Fix round 3, N2: two registrations for one plan (an adopt's size measurement and a credential check) can
    /// overlap; the first to end mustn't end the other's, or deleting the plan wouldn't wait for it.
    @Test func overlappingMeasurementsAreCounted() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await state.beginMeasurement(planID: plan.id)
        try await state.beginMeasurement(planID: plan.id)
        await state.endMeasurement(planID: plan.id)
        #expect(await state.isMeasuring(plan.id))
        await state.endMeasurement(planID: plan.id)
        #expect(await !state.isMeasuring(plan.id))
        // An end with nothing registered changes nothing.
        await state.endMeasurement(planID: plan.id)
        #expect(await !state.isMeasuring(plan.id))
    }

    /// Fix round 3, N3: the status carries the newest backup of any outcome (for Done) and the newest backup with a
    /// verdict (for the menu's failure line, as `activeConditions` decides `backupFailed`).
    @Test func theStatusCarriesTheNewestBackupAndTheNewestVerdict() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        func record(_ outcome: RunOutcome, _ minutes: Double) -> RunRecord {
            RunRecord(
                id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
                startedAt: clock.now.addingTimeInterval(minutes * 60), endedAt: clock.now.addingTimeInterval(minutes * 60),
                outcome: outcome, summary: nil, logFile: "")
        }
        let failed = record(.wrongPassword, 1)
        let skipped = record(.skipped(.onBattery), 2)
        try await state.updateHistory(plan.id) { history in
            history.record(failed)
            history.record(skipped)
        }
        let status = try #require(await state.status().plans.first)
        #expect(status.latestBackupRecord == skipped)
        #expect(status.latestBackupVerdict == failed)
    }

    // MARK: Runs need the runner

    /// Runs are the plan runner's (PlanRunnerTests); with none attached they are refused, not dropped.
    @Test func runActionsNeedTheRunner() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        await #expect(throws: AgentError.runnerUnavailable) { try await state.backUpNow(plan.id) }
        await #expect(throws: AgentError.runnerUnavailable) { try await state.createRepository(plan.id) }
        await #expect(throws: AgentError.runnerUnavailable) { _ = try await state.adopt(plan.id) }
        await #expect(throws: AgentError.runnerUnavailable) { _ = try await state.probeRepository(plan.id) }
        await #expect(throws: AgentError.runnerUnavailable) { try await state.probeFullDiskAccess() }
        #expect(AgentError.runnerUnavailable.message == "Restorey is still starting up. Try again in a moment")
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

    /// Cancel only stops work, so a drain doesn't refuse it (like Pause), and it changes no pause.
    @Test func cancelIsAllowedWhileDraining() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await state.beginRun(planID: plan.id)
        let drain = Task { await state.prepareForRestart() }
        try await Self.waitUntilDraining(state)

        let before = await state.status()
        let status = try await state.cancel(plan.id)
        #expect(status.plans == before.plans, "no runner, so nothing to stop and nothing changes")
        #expect(try await state.runInputs(plan.id).history.pausedUntil == nil)

        await state.endRun(planID: plan.id)
        await drain.value
    }

    /// Like Pause, Cancel is refused when the settings can't be read, and for a plan that doesn't exist.
    @Test func cancelIsRefusedForAnUnknownPlan() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        await #expect { _ = try await state.cancel(UUID()) } throws: { ($0 as? AgentError) == .unknownPlan }
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

        let refused = "Restorey is finishing the current backup before updating"
        await #expect { try await state.backUpNow(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.backUpNow(nil) } throws: { Self.message($0) == refused }
        await #expect { try await state.createRepository(plan.id) } throws: { Self.message($0) == refused }
        await #expect { _ = try await state.adopt(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.savePlan(Self.request(plan)) } throws: { Self.message($0) == refused }
        await #expect { try await state.deletePlan(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.confirmRecoveryKit(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.resume(plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.beginRun(planID: plan.id) } throws: { Self.message($0) == refused }
        await #expect { try await state.saveNetworkSettings(.defaults) } throws: { Self.message($0) == refused }
        let other = Self.plan(now: clock.now)
        await #expect { try await state.beginRun(planID: other.id) } throws: { Self.message($0) == refused }
        // Pause is allowed, so the user can still stop a long first backup.
        _ = try await state.pause(plan.id, for: .oneHour)
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
        _ = try await state.pause(plan.id, for: .oneHour)   // gives the plan a history entry
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
        // Replies without waiting on anything: well under the ping budget the drain would otherwise be held to.
        #expect(ContinuousClock.now - start < AgentState.drainPingBudget / 2)
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

// MARK: Draining before re-registration (Ruling R51)

extension AgentStateTests {
    @Test func reregistrationDrainWaitsForInFlightRun() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let events = EventLog()
        let run = try await Self.fakeRun(state, planID: plan.id, seconds: 2, events: events)

        let drain = Task {
            _ = try? await state.prepareForReregistration()
            await events.append("drained")
        }
        try await Self.waitUntilDraining(state)
        await run.value
        await drain.value
        #expect(await events.items == ["run ended", "drained"])
    }

    /// The agent stays up after this drain: only a restart drain exits (AgentService acts on
    /// `exitsAfterwards`), so `unregister()` stops this drained process, not a fresh KeepAlive launch.
    @Test func reregistrationDrainDoesNotExit() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        try await state.prepareForReregistration()
        #expect(await state.drainPurpose == .reregistration)
        #expect(!DrainPurpose.reregistration.exitsAfterwards)
        #expect(DrainPurpose.restart.exitsAfterwards)
        // A later restart drain (an app that finds the agent stuck drained) does exit.
        await state.prepareForRestart()
        #expect(await state.drainPurpose == .restart)
    }

    /// While a restart drain is under way the agent will exit on its own, so a re-registration drain is
    /// refused rather than answered "drained": the app's `unregister()` would otherwise meet the fresh
    /// agent launchd starts (fix round 1 of Ruling R55). One asked for before the restart began is
    /// refused once its wait ends. The agent still exits exactly once.
    @Test func reregistrationIsRefusedDuringASelfStartedRestartDrain() async throws {
        let dir = try TempDirectory()
        let clock = TestClock()
        let state = await Self.makeState(dir, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        let exits = Locked(0)
        await state.attach(restartExit: { exits.mutate { $0 += 1 } }, log: { _ in })
        let events = EventLog()
        let run = try await Self.fakeRun(state, planID: plan.id, seconds: 1, events: events)

        let early = Task { () -> AgentError? in
            do { try await state.prepareForReregistration(); return nil } catch { return error as? AgentError }
        }
        try await Self.waitUntilDraining(state)
        await state.restartForReplacedBinary()
        await #expect(throws: AgentError.restarting) { try await state.prepareForReregistration() }

        await run.value
        #expect(await early.value == .restarting)
        #expect(await state.drainPurpose == .restart)
        while exits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(exits.value == 1)
        #expect(AgentError.restarting.message == "Restorey is restarting to finish an update. Try again in a moment")
    }

    @Test func reregistrationIsRefusedDuringTheAppsRestartDrain() async throws {
        let dir = try TempDirectory()
        let state = await Self.makeState(dir)
        await state.prepareForRestart()
        await #expect(throws: AgentError.restarting) { try await state.prepareForReregistration() }
    }

    @Test func mutatingCallsAreRefusedAfterReregistrationDrainUntilRestart() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        let plan = Self.plan(now: clock.now)
        _ = try await state.savePlan(Self.request(plan))
        try await state.prepareForReregistration()

        #expect(await state.isDraining)
        await #expect(throws: AgentError.draining) { try await state.savePlan(Self.request(plan)) }
        await #expect(throws: AgentError.draining) { try await state.backUpNow(nil) }
        await #expect(throws: AgentError.draining) { try await state.backUpNow(plan.id) }
        await #expect(throws: AgentError.draining) { try await state.resume(plan.id) }
        await #expect(throws: AgentError.draining) { try await state.confirmRecoveryKit(plan.id) }
        await #expect(throws: AgentError.draining) { try await state.deletePlan(plan.id) }
        await #expect(throws: AgentError.draining) { try await state.beginRun(planID: plan.id) }

        // The registered agent that launchd starts next is a new process over the same files.
        let restarted = await Self.makeState(dir, secrets: secrets, clock: clock)
        #expect(!(await restarted.isDraining))
        #expect(await restarted.drainPurpose == nil)
        _ = try await restarted.savePlan(Self.request(plan))
    }
}

// MARK: Removing a check-in URL (Ruling R51)

extension AgentStateTests {
    @Test func savingWithoutCheckInURLDeletesTheStoredOne() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let state = await Self.makeState(dir, secrets: secrets, clock: clock)
        var plan = Self.plan(now: clock.now)
        plan.hasCheckInURL = true
        var request = Self.request(plan)
        request.secrets.append(SecretEntry(key: .checkInURL(plan.id), value: "https://hc.example/ping/abc"))
        _ = try await state.savePlan(request)
        _ = try await state.confirmRecoveryKit(plan.id)
        #expect(try secrets.read(.checkInURL(plan.id)) == "https://hc.example/ping/abc")

        plan.hasCheckInURL = false
        let status = try await state.savePlan(SavePlanRequest(plan: plan, secrets: []))
        #expect(try secrets.read(.checkInURL(plan.id)) == nil)
        #expect(status.plans.first?.plan.hasCheckInURL == false)
        // Removing monitoring isn't a credentials change, so the recovery kit stays confirmed.
        #expect(status.plans.first?.plan.recoveryKitConfirmedAt != nil)
    }

    @Test func checkInURLForAPlanWithoutOneIsRefused() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let state = await Self.makeState(dir, secrets: secrets)
        let plan = Self.plan(now: Date())
        var request = Self.request(plan)
        request.secrets.append(SecretEntry(key: .checkInURL(plan.id), value: "https://hc.example/ping/abc"))
        await #expect(throws: AgentError.self) { try await state.savePlan(request) }
        #expect(try secrets.read(.checkInURL(plan.id)) == nil)
        #expect(try secrets.read(.repositoryPassword(plan.id)) == nil)
    }

    /// A failed config write puts a deleted check-in URL back.
    @Test func failedSaveRestoresADeletedCheckInURL() async throws {
        let dir = try TempDirectory()
        let secrets = InMemorySecretStore()
        let clock = TestClock()
        let store = ControlledStore(AgentState.configStore(in: dir.url))
        let state = await Self.makeState(dir, configStore: store, secrets: secrets, clock: clock)
        var plan = Self.plan(now: clock.now)
        plan.hasCheckInURL = true
        var request = Self.request(plan)
        request.secrets.append(SecretEntry(key: .checkInURL(plan.id), value: "https://hc.example/ping/abc"))
        _ = try await state.savePlan(request)

        await store.failNextSave()
        plan.hasCheckInURL = false
        await #expect(throws: AgentError.self) { try await state.savePlan(SavePlanRequest(plan: plan, secrets: [])) }
        #expect(try secrets.read(.checkInURL(plan.id)) == "https://hc.example/ping/abc")
    }
}
