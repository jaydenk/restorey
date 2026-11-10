import Foundation
import Synchronization
import Testing
@testable import RestoreyCore

struct VersionedStoreTests {
    struct Doc: Codable, Sendable, Equatable {
        var name: String
        var count: Int
        var when: Date
    }

    private static let when = Date(timeIntervalSince1970: 1_800_000_000)

    /// A fresh directory per test, removed afterwards by the caller.
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store(_ dir: URL, version: Int = 1,
                       migrations: [Int: @Sendable (inout [String: Any]) throws -> Void] = [:]) -> VersionedStore<Doc> {
        VersionedStore(fileURL: dir.appendingPathComponent("config.json"), currentVersion: version, migrations: migrations)
    }

    @Test func missingFileLoadsNil() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await store(dir).load() == nil)
    }

    @Test func saveThenLoadRoundTrips() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir)
        let doc = Doc(name: "a", count: 2, when: Self.when)
        try await s.save(doc)
        #expect(try await s.load() == doc)

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("config.json"))
        ) as? [String: Any]
        #expect(raw?["schemaVersion"] as? Int == 1)
        #expect((raw?["payload"] as? [String: Any])?["when"] as? String == "2027-01-15T08:00:00.000Z")
    }

    @Test func newerSchemaIsRefusedAndFileUntouched() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let bytes = Data(#"{"schemaVersion": 99, "payload": {"anything": true}}"#.utf8)
        try bytes.write(to: file)

        await #expect(throws: VersionedStoreError.newerSchema(found: 99, supported: 1)) {
            try await store(dir).load()
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func corruptFileIsRefusedAndFileUntouched() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let cases = [
            Data("not json at all".utf8),
            Data(#"{"payload": {}}"#.utf8),
            Data(#"{"schemaVersion": 1, "payload": {"name": 5}}"#.utf8),
        ]
        for bytes in cases {
            try bytes.write(to: file)
            do {
                _ = try await store(dir).load()
                Issue.record("Expected a corrupt error for \(String(decoding: bytes, as: UTF8.self))")
            } catch let error as VersionedStoreError {
                guard case .corrupt = error else {
                    Issue.record("Expected corrupt, got \(error)")
                    continue
                }
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func migrationRunsInOrder() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try Data(#"{"schemaVersion": 1, "payload": {"title": "x", "when": "2027-01-15T08:00:00Z"}}"#.utf8)
            .write(to: file)

        let log = Mutex<[String]>([])
        let s = store(dir, version: 3, migrations: [
            1: { payload in
                log.withLock { $0.append("1->2") }
                payload["name"] = payload.removeValue(forKey: "title")
            },
            2: { payload in
                log.withLock { $0.append("2->3") }
                // Depends on 1->2 having run first.
                payload["count"] = (payload["name"] as? String)?.count ?? -1
            },
        ])

        let loaded = try await s.load()
        #expect(loaded == Doc(name: "x", count: 1, when: Self.when))
        #expect(log.withLock { $0 } == ["1->2", "2->3"])

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(raw?["schemaVersion"] as? Int == 3)

        // Already at the current version: nothing runs again.
        _ = try await s.load()
        #expect(log.withLock { $0.count } == 2)
    }

    @Test func failedMigrationDecodeLeavesFileAtOldVersion() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let bytes = Data(#"{"schemaVersion": 1, "payload": {"title": "x"}}"#.utf8)
        try bytes.write(to: file)

        // The migration does not produce the fields Doc needs.
        let s = store(dir, version: 2, migrations: [1: { _ in }])
        do {
            _ = try await s.load()
            Issue.record("Expected a corrupt error")
        } catch let error as VersionedStoreError {
            guard case .corrupt = error else { Issue.record("Expected corrupt, got \(error)"); return }
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func missingMigrationIsRefused() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"schemaVersion": 1, "payload": {}}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        await #expect(throws: VersionedStoreError.missingMigration(from: 1)) {
            try await store(dir, version: 2).load()
        }
    }

    @Test func newerSchemaWithDifferentEnvelopeShapeIsStillNewer() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"schemaVersion": 99, "payload": [1, 2]}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        await #expect(throws: VersionedStoreError.newerSchema(found: 99, supported: 1)) {
            try await store(dir).load()
        }
    }

    @Test func saveNeverOverwritesARefusedFile() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let doc = Doc(name: "new", count: 1, when: Self.when)

        let newer = Data(#"{"schemaVersion": 99, "payload": {}}"#.utf8)
        try newer.write(to: file)
        await #expect(throws: VersionedStoreError.newerSchema(found: 99, supported: 1)) {
            try await store(dir).save(doc)
        }
        #expect(try Data(contentsOf: file) == newer)

        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        do {
            try await store(dir).save(doc)
            Issue.record("Expected a corrupt error")
        } catch let error as VersionedStoreError {
            guard case .corrupt = error else { Issue.record("Expected corrupt, got \(error)"); return }
        }
        #expect(try Data(contentsOf: file) == corrupt)

        let old = Data(#"{"schemaVersion": 1, "payload": {}}"#.utf8)
        try old.write(to: file)
        await #expect(throws: VersionedStoreError.missingMigration(from: 1)) {
            try await store(dir, version: 2).save(doc)
        }
        #expect(try Data(contentsOf: file) == old)
    }

    @Test func saveOverwritesAValidCurrentFile() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir)
        try await s.save(Doc(name: "a", count: 1, when: Self.when))
        try await s.save(Doc(name: "b", count: 2, when: Self.when))
        #expect(try await s.load()?.name == "b")
    }

    /// The failure is injected by making the directory read-only after the first save, so the
    /// temporary file cannot be created. The old file must survive byte for byte.
    @Test func saveIsAtomic() async throws {
        let dir = try makeDirectory()
        let file = dir.appendingPathComponent("config.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let s = store(dir)
        try await s.save(Doc(name: "old", count: 1, when: Self.when))
        let before = try Data(contentsOf: file)

        // Success leaves no temporary file behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"])

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        await #expect(throws: (any Error).self) {
            try await s.save(Doc(name: "new", count: 2, when: Self.when))
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"])
        #expect(try await s.load() == Doc(name: "old", count: 1, when: Self.when))
    }
}
