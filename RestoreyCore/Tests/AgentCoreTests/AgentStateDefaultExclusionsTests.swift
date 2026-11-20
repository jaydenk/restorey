import Foundation
import Synchronization
import Testing
@testable import AgentCore
import RestoreyCore

/// A default exclusion added after a plan was made reaches that plan once (owner, 20 Nov 2026): the agent adds it after
/// loading `config.json`, and one the person later removes stays removed.
struct AgentStateDefaultExclusionsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let home = URL(fileURLWithPath: "/Users/me")
    private static let coreSpeech = "/Users/me/Library/Group Containers/group.com.apple.CoreSpeech/Caches"

    private static func plan(name: String = "Home", exclusions: [String], revision: Int) -> Plan {
        var plan = Plan.newHotPlan(
            name: name, repository: .raw(repository: "/tmp/repo", environmentNames: []), origin: .created,
            hostLabel: "mac", sources: ["/Users/me"], exclusions: exclusions, now: now)
        plan.exclusionDefaultsRevision = revision
        return plan
    }

    /// The lines the agent logged.
    private final class Lines: Sendable {
        private let value = Mutex<[String]>([])
        var all: [String] { value.withLock { $0 } }
        func append(_ line: String) { value.withLock { $0.append(line) } }
    }

    private struct Loaded {
        let state: AgentState
        let store: AgentStateTests.ControlledStore<ConfigFile>
        let log: Lines
    }

    /// Writes `plans` to `config.json`, then starts an agent on it and has it add the new defaults.
    private static func load(_ dir: AgentStateTests.TempDirectory, writing plans: [Plan]? = nil) async throws -> Loaded {
        if let plans { try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: plans)) }
        let store = AgentStateTests.ControlledStore(AgentState.configStore(in: dir.url))
        let state = await AgentState(
            configStore: store, stateStore: AgentState.stateStore(in: dir.url), secrets: InMemorySecretStore(),
            credentialsDirectory: dir.url, now: { now })
        let log = Lines()
        await state.attach(agentLog: { log.append($0) })
        await state.addNewDefaultExclusions(home: home)
        return Loaded(state: state, store: store, log: log)
    }

    private static func onDisk(_ dir: AgentStateTests.TempDirectory) async throws -> [Plan] {
        try #require(try await AgentState.configStore(in: dir.url).load()).plans
    }

    @Test func aRevisionOnePlanGainsTheCoreSpeechCachesOnce() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let own = ["/Users/me/Library/Caches", "**/scratch"]
        let loaded = try await Self.load(dir, writing: [Self.plan(exclusions: own, revision: 1)])

        let plan = try #require(await loaded.state.status().plans.first?.plan)
        #expect(plan.exclusions == own + [Self.coreSpeech], "added at the end, the rest untouched")
        #expect(plan.exclusionDefaultsRevision == DefaultExclusions.revision)
        #expect(await loaded.store.saveCount == 1)
        #expect(try await Self.onDisk(dir) == [plan])
        let lines = loaded.log.all
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Home") == true, "\(lines)")
        #expect(lines.first?.contains(Self.coreSpeech) == true, "\(lines)")

        // The next start finds nothing to add and writes nothing.
        let again = try await Self.load(dir)
        #expect(await again.state.status().plans.first?.plan == plan)
        #expect(await again.store.saveCount == 0)
        #expect(again.log.all.isEmpty)
    }

    @Test func aPlanThatAlreadyListsItIsntGivenADuplicate() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let own = [Self.coreSpeech, "**/scratch"]
        let loaded = try await Self.load(dir, writing: [Self.plan(exclusions: own, revision: 1)])

        let plan = try #require(await loaded.state.status().plans.first?.plan)
        #expect(plan.exclusions == own)
        #expect(plan.exclusionDefaultsRevision == DefaultExclusions.revision)
        // The revision moved on, so the file is written, once; nothing was added, so nothing is logged.
        #expect(await loaded.store.saveCount == 1)
        #expect(try await Self.onDisk(dir) == [plan])
        #expect(loaded.log.all.isEmpty)
    }

    /// The person removed the default from a plan that already had this revision: it stays removed, and the file
    /// isn't written at all.
    @Test func aDefaultThePersonRemovedStaysRemoved() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let current = Self.plan(exclusions: ["**/scratch"], revision: DefaultExclusions.revision)
        try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: [current]))
        let before = try Data(contentsOf: dir.config)

        let loaded = try await Self.load(dir)
        #expect(await loaded.state.status().plans.map(\.plan) == [current])
        #expect(await loaded.store.saveCount == 0)
        #expect(try Data(contentsOf: dir.config) == before)
    }

    /// Only the plans behind are changed, with one write for all of them and a line for each plan given a pattern.
    @Test func onlyThePlansBehindAreChangedInOneWrite() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let behind = Self.plan(name: "Home", exclusions: [], revision: 1)
        let alsoBehind = Self.plan(name: "Work", exclusions: [], revision: 1)
        let current = Self.plan(name: "Photos", exclusions: [], revision: DefaultExclusions.revision)
        let loaded = try await Self.load(dir, writing: [behind, current, alsoBehind])

        let plans = await loaded.state.status().plans.map(\.plan)
        #expect(plans.map(\.exclusions) == [[Self.coreSpeech], [], [Self.coreSpeech]])
        #expect(plans.allSatisfy { $0.exclusionDefaultsRevision == DefaultExclusions.revision })
        #expect(await loaded.store.saveCount == 1)
        let lines = loaded.log.all
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("Home") } && lines.contains { $0.contains("Work") }, "\(lines)")
    }

    /// A failed write leaves the plans as they were in memory, so the next start tries again.
    @Test func aFailedWriteChangesNothing() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let behind = Self.plan(exclusions: [], revision: 1)
        try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: [behind]))
        let store = AgentStateTests.ControlledStore(AgentState.configStore(in: dir.url))
        await store.failNextSave()
        let state = await AgentState(
            configStore: store, stateStore: AgentState.stateStore(in: dir.url), secrets: InMemorySecretStore(),
            credentialsDirectory: dir.url, now: { Self.now })
        let log = Lines()
        await state.attach(agentLog: { log.append($0) })
        await state.addNewDefaultExclusions(home: Self.home)

        #expect(await state.status().plans.map(\.plan) == [behind])
        #expect(try await Self.onDisk(dir) == [behind])
        #expect(log.all.contains { $0.contains("couldn’t") }, "the failure is logged")
    }

    /// In the config-error state the agent never writes `config.json`.
    @Test func nothingIsWrittenInTheConfigErrorState() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let bad = Data(#"{"schemaVersion": 99, "payload": {}}"#.utf8)
        try bad.write(to: dir.config)
        let loaded = try await Self.load(dir)
        #expect(await loaded.state.status().configError != nil)
        #expect(await loaded.store.saveCount == 0)
        #expect(try Data(contentsOf: dir.config) == bad)
    }

    /// The revision is the agent's: a save carrying a lower one (an editor opened before the agent added a default)
    /// keeps the stored revision, so a default the person then removes isn't added again.
    @Test func savingAPlanKeepsTheStoredRevision() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let loaded = try await Self.load(dir, writing: [Self.plan(exclusions: [], revision: 1)])
        var edited = try #require(await loaded.state.status().plans.first?.plan)
        edited.exclusions = []
        edited.exclusionDefaultsRevision = 1
        _ = try await loaded.state.savePlan(SavePlanRequest(plan: edited, secrets: []))

        let saved = try #require(try await Self.onDisk(dir).first)
        #expect(saved.exclusions.isEmpty)
        #expect(saved.exclusionDefaultsRevision == DefaultExclusions.revision)
        let restarted = try await Self.load(dir)
        #expect(await restarted.state.status().plans.first?.plan.exclusions == [])
    }
}
