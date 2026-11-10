import Foundation

public enum VersionedStoreError: Error, Equatable {
    /// The file was written by a newer Restorey. It is left untouched.
    case newerSchema(found: Int, supported: Int)
    /// The file is not valid JSON, not shaped like an envelope, or its payload does not decode.
    /// It is left untouched.
    case corrupt(underlying: String)
    /// The file is at an older version and no migration is registered for it.
    case missingMigration(from: Int)
}

/// A JSON file holding `{"schemaVersion": n, "payload": {...}}`, written atomically and migrated
/// forward on load. Holds `config.json` and `state.json`. The payload must encode to a JSON object.
public actor VersionedStore<Payload: Codable & Sendable> {
    private let fileURL: URL
    private let currentVersion: Int
    private let migrations: [Int: @Sendable (inout [String: Any]) throws -> Void]

    public init(
        fileURL: URL,
        currentVersion: Int,
        migrations: [Int: @Sendable (inout [String: Any]) throws -> Void]
    ) {
        self.fileURL = fileURL
        self.currentVersion = currentVersion
        self.migrations = migrations
    }

    /// The stored payload, or nil when there is no file. A migrated file is rewritten at the
    /// current version only after the migrated payload decodes.
    public func load() throws -> Payload? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["schemaVersion"] as? Int,
              var payload = root["payload"] as? [String: Any]
        else {
            throw VersionedStoreError.corrupt(underlying: "Expected an object with schemaVersion and payload.")
        }
        guard version <= currentVersion else {
            throw VersionedStoreError.newerSchema(found: version, supported: currentVersion)
        }
        guard version >= 1 else {
            throw VersionedStoreError.corrupt(underlying: "Invalid schemaVersion \(version).")
        }

        for from in version..<currentVersion {
            guard let migrate = migrations[from] else {
                throw VersionedStoreError.missingMigration(from: from)
            }
            do {
                try migrate(&payload)
            } catch {
                throw VersionedStoreError.corrupt(underlying: "Migration from version \(from) failed: \(error)")
            }
        }

        let decoded: Payload
        do {
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            decoded = try Self.makeDecoder().decode(Payload.self, from: payloadData)
        } catch {
            throw VersionedStoreError.corrupt(underlying: String(describing: error))
        }

        if version < currentVersion {
            try save(decoded)
        }
        return decoded
    }

    /// Replaces the file atomically: the data is written to a temporary file and renamed over the
    /// old one, so a failure leaves the previous file intact.
    public func save(_ payload: Payload) throws {
        let payloadData = try Self.makeEncoder().encode(payload)
        guard let object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw VersionedStoreError.corrupt(underlying: "Payload does not encode to a JSON object.")
        }
        let envelope: [String: Any] = ["schemaVersion": currentVersion, "payload": object]
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
