import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

/// `config.json` schema 1 → 2 (Ruling R64): plans gain `fileTypeExclusions` and `oneFileSystem`; 2 → 3 (Ruling
/// P2-6): the constrained-network rule moves to the Mac-wide `network` settings.
struct ConfigMigrationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func plan(exclusions: [String]) -> Plan {
        Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/tmp/repo", environmentNames: []), origin: .created,
            hostLabel: "mac", sources: ["/Users/me"], exclusions: exclusions, now: now)
    }

    /// Writes a file at an older schema as earlier builds wrote it: saved by today's store (its date format
    /// and layout), then taken back. Schema 2 had no `network` and kept `skipOnConstrainedNetwork` in each
    /// plan's conditions (`skips` gives each plan's value, default true), and no `setupCompletedAt` or
    /// `offMacNoteDismissed`; schema 1 also lacked `fileTypeExclusions` and `oneFileSystem`.
    private static func writeOldFile(
        _ plans: [Plan], version: Int, skips: [Bool]? = nil, in dir: AgentStateTests.TempDirectory
    ) async throws {
        try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: plans))
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.config)) as? [String: Any])
        var payload = try #require(root["payload"] as? [String: Any])
        var list = try #require(payload["plans"] as? [[String: Any]])
        for index in list.indices {
            list[index]["setupCompletedAt"] = nil
            list[index]["offMacNoteDismissed"] = nil
            var conditions = try #require(list[index]["conditions"] as? [String: Any])
            conditions["skipOnConstrainedNetwork"] = skips?[index] ?? true
            list[index]["conditions"] = conditions
            if version < 2 {
                list[index]["fileTypeExclusions"] = nil
                list[index]["oneFileSystem"] = nil
            }
        }
        payload["plans"] = list
        payload["network"] = nil
        root["payload"] = payload
        root["schemaVersion"] = version
        try JSONSerialization.data(withJSONObject: root).write(to: dir.config)
    }

    /// What schema 1 → 2 gives every old plan, written out: a later change to `Self.schema2FileTypes`
    /// must not change it.
    private static let schema2FileTypes = [
        "dmg", "iso", "sparseimage",
        "vmdk", "vhd", "vhdx", "vdi", "qcow2", "hdd", "hds", "pvm", "pvs", "pvi", "pva", "fdd", "vmc",
        "vmx", "vmxf", "vmsn", "vmsd", "vmem", "nvram", "mem", "vsv",
    ]

    @Test func aVersion1ConfigMigratesAndKeepsThePersonsFolderExclusions() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let own = ["/Users/me/Movies/Rendered", "**/scratch"]
        let original = Self.plan(exclusions: own)
        try await Self.writeOldFile([original], version: 1, in: dir)

        let loaded = try #require(try await AgentState.configStore(in: dir.url).load())
        let migrated = try #require(loaded.plans.first)
        #expect(migrated.fileTypeExclusions == Self.schema2FileTypes)
        #expect(migrated.oneFileSystem)
        #expect(migrated.exclusions == own)
        var expected = original
        expected.fileTypeExclusions = Self.schema2FileTypes
        expected.oneFileSystem = true
        #expect(migrated == expected)

        // Rewritten at the current version, and a second load reads it as is.
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.config)) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == ConfigMigrations.currentVersion)
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

    /// An older agent (schema 2) meeting a file this version wrote refuses it as newer and leaves it alone,
    /// the existing rule; the agent then sits in the config-error state (`configErrorBlocksEverything`).
    @Test func anOlderAgentRefusesAVersion3FileAndLeavesItAlone() async throws {
        let dir = try AgentStateTests.TempDirectory()
        try await AgentState.configStore(in: dir.url).save(ConfigFile(plans: [Self.plan(exclusions: [])]))
        let before = try Data(contentsOf: dir.config)
        let older = VersionedStore<ConfigFile>(fileURL: dir.config, currentVersion: 2, migrations: [:])
        await #expect(throws: VersionedStoreError.newerSchema(found: 3, supported: 2)) { try await older.load() }
        await #expect(throws: VersionedStoreError.newerSchema(found: 3, supported: 2)) {
            try await older.save(ConfigFile())
        }
        #expect(try Data(contentsOf: dir.config) == before)
    }

    /// Schema 2 → 3 (Ruling P2-6) through the real store: the constrained-network rule moves to the Mac-wide
    /// `network` settings, on if any plan had it on, and a plan whose kit was confirmed has finished setup.
    @Test func aVersion2ConfigMigratesToVersion3() async throws {
        let dir = try AgentStateTests.TempDirectory()
        var confirmed = Self.plan(exclusions: ["/Users/me/x"])
        confirmed.recoveryKitConfirmedAt = Self.now.addingTimeInterval(-86_400)
        let unconfirmed = Self.plan(exclusions: [])
        try await Self.writeOldFile([confirmed, unconfirmed], version: 2, skips: [false, true], in: dir)

        let loaded = try #require(try await AgentState.configStore(in: dir.url).load())
        #expect(loaded.network == .defaults)
        var expectedConfirmed = confirmed
        expectedConfirmed.setupCompletedAt = confirmed.recoveryKitConfirmedAt
        #expect(loaded.plans == [expectedConfirmed, unconfirmed])
        #expect(loaded.plans[1].setupCompletedAt == nil)
        #expect(loaded.plans.allSatisfy { !$0.offMacNoteDismissed })

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.config)) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 3)
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("config.json.v2.bak").path))

        // Every plan had it off: so does the Mac.
        let off = try AgentStateTests.TempDirectory()
        try await Self.writeOldFile([confirmed, unconfirmed], version: 2, skips: [false, false], in: off)
        #expect(try await AgentState.configStore(in: off.url).load()?.network.skipOnConstrainedNetwork == false)
    }

    /// The agent itself: a version-1 config.json loads with the plan migrated, no config error.
    @Test func theAgentLoadsAVersion1Config() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let original = Self.plan(exclusions: ["/Users/me/x"])
        try await Self.writeOldFile([original], version: 1, in: dir)
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: { Self.now })
        let status = await state.status()
        #expect(status.configError == nil)
        #expect(status.network == .defaults)
        #expect(status.plans.first?.plan.fileTypeExclusions == Self.schema2FileTypes)
        #expect(status.plans.first?.plan.exclusions == ["/Users/me/x"])
        // The schema-1 file is kept beside the migrated one (Ruling R72).
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("config.json.v1.bak").path))
    }

    /// Ruling R72: a migration that throws is reported as such, and the agent's config-error state is as
    /// before: nothing runs, nothing is written.
    @Test func aThrowingMigrationPutsTheAgentInTheConfigErrorState() async throws {
        let dir = try AgentStateTests.TempDirectory()
        let bad = Data(#"{"schemaVersion": 1, "payload": {"plans": "nope"}}"#.utf8)
        try bad.write(to: dir.config)
        await #expect(throws: VersionedStoreError.migrationFailed(from: 1, underlying: "notAPlanList")) {
            try await AgentState.configStore(in: dir.url).load()
        }
        let state = await AgentState(directory: dir.url, secrets: InMemorySecretStore(), now: { Self.now })
        let error = try #require(await state.status().configError)
        #expect(error.hasPrefix("config.json couldn't be upgraded from schema 1"), "\(error)")
        #expect(try Data(contentsOf: dir.config) == bad)
    }
}
