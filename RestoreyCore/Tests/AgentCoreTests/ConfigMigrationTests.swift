import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// `config.json` schema 1 → 2 (Ruling R64): plans gain `fileTypeExclusions` and `oneFileSystem`.
struct ConfigMigrationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func plan(exclusions: [String]) -> Plan {
        Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/tmp/repo", environmentNames: []), origin: .created,
            hostLabel: "mac", sources: ["/Users/me"], exclusions: exclusions, now: now)
    }

    /// Writes a schema-1 file as v0.1 alpha builds wrote it: saved by today's store (its date format and
    /// layout), then taken back to version 1 by removing the two new keys.
    private static func writeVersion1File(_ plans: [Plan], in dir: AgentStateTests.TempDirectory) async throws {
        try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: plans))
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.config)) as? [String: Any])
        var payload = try #require(root["payload"] as? [String: Any])
        var list = try #require(payload["plans"] as? [[String: Any]])
        for index in list.indices {
            list[index]["fileTypeExclusions"] = nil
            list[index]["oneFileSystem"] = nil
        }
        payload["plans"] = list
        root["payload"] = payload
        root["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: root).write(to: dir.config)
    }

    /// What schema 1 → 2 gives every old plan, written out: a later change to `Self.schema2FileTypes`
    /// must not change it.
    private static let schema2FileTypes = [
        "dmg", "iso", "sparseimage",
        "vmdk", "vhd", "vhdx", "vdi", "qcow2", "hdd", "hds", "pvm", "pvs", "pvi", "pva", "fdd", "vmc",
        "vmx", "vmxf", "vmsn", "vmsd", "vmem", "nvram", "mem", "vsv",
    ]

    @Test func currentVersionIsTwo() {
        #expect(ConfigMigrations.currentVersion == 2)
    }

    @Test func aVersion1ConfigMigratesAndKeepsThePersonsFolderExclusions() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let own = ["/Users/me/Movies/Rendered", "**/scratch"]
        let original = Self.plan(exclusions: own)
        try await Self.writeVersion1File([original], in: dir)

        let loaded = try #require(try await AgentState.configStore(in: dir.url).load())
        let migrated = try #require(loaded.plans.first)
        #expect(migrated.fileTypeExclusions == Self.schema2FileTypes)
        #expect(migrated.oneFileSystem)
        #expect(migrated.exclusions == own)
        var expected = original
        expected.fileTypeExclusions = Self.schema2FileTypes
        expected.oneFileSystem = true
        #expect(migrated == expected)

        // Rewritten at version 2, and a second load reads it as is.
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.config)) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 2)
        #expect(try await AgentState.configStore(in: dir.url).load() == loaded)
    }

    @Test func aPlanThatAlreadyHasTheKeysKeepsItsValues() throws {
        var payload: [String: Any] = ["plans": [["fileTypeExclusions": ["iso"], "oneFileSystem": false]]]
        try ConfigMigrations.addFileTypeExclusionsAndOneFileSystem(&payload)
        let plan = try #require((payload["plans"] as? [[String: Any]])?.first)
        #expect(plan["fileTypeExclusions"] as? [String] == ["iso"])
        #expect(plan["oneFileSystem"] as? Bool == false)
    }

    @Test func aPlanListThatIsntOneIsRefusedAndTheFileLeftAlone() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let bad = Data(#"{"schemaVersion": 1, "payload": {"plans": "nope"}}"#.utf8)
        try bad.write(to: dir.config)
        await #expect(throws: VersionedStoreError.self) { try await AgentState.configStore(in: dir.url).load() }
        #expect(try Data(contentsOf: dir.config) == bad)
    }

    @Test func aCurrentConfigRoundTrips() async throws {
        let dir = try AgentStateTests.TempDirectory()
        var plan = Self.plan(exclusions: ["/Users/me/Library/Caches"])
        plan.fileTypeExclusions = ["dmg", "qcow2"]
        plan.oneFileSystem = false
        let store = AgentState.configStore(in: dir.url)
        try await store.save(ConfigFile(plans: [plan]))
        #expect(try await AgentState.configStore(in: dir.url).load() == ConfigFile(plans: [plan]))
    }

    /// An older agent (schema 1) meeting a file this version wrote refuses it as newer and leaves it alone,
    /// the existing rule; the agent then sits in the config-error state (`configErrorBlocksEverything`).
    @Test func anOlderAgentRefusesAVersion2FileAndLeavesItAlone() async throws {
        let dir = try AgentStateTests.TempDirectory()
        try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: [Self.plan(exclusions: [])]))
        let before = try Data(contentsOf: dir.config)
        let older = VersionedStore<ConfigFile>(fileURL: dir.config, currentVersion: 1, migrations: [:])
        await #expect(throws: VersionedStoreError.newerSchema(found: 2, supported: 1)) { try await older.load() }
        await #expect(throws: VersionedStoreError.newerSchema(found: 2, supported: 1)) {
            try await older.save(ConfigFile())
        }
        #expect(try Data(contentsOf: dir.config) == before)
    }

    /// The agent itself: a version-1 config.json loads with the plan migrated, no config error.
    @Test func theAgentLoadsAVersion1Config() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let original = Self.plan(exclusions: ["/Users/me/x"])
        try await Self.writeVersion1File([original], in: dir)
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: { Self.now })
        let status = await state.status()
        #expect(status.configError == nil)
        #expect(status.plans.first?.plan.fileTypeExclusions == Self.schema2FileTypes)
        #expect(status.plans.first?.plan.exclusions == ["/Users/me/x"])
    }
}
