import Foundation

public enum VersionedStoreError: Error, Equatable {
    /// The file was written by a newer Restorey. It is left untouched.
    case newerSchema(found: Int, supported: Int)
    /// The file is not valid JSON, not shaped like an envelope, or its payload does not decode.
    /// It is left untouched.
    case corrupt(underlying: String)
    /// The file is at an older version and no migration is registered for it.
    case missingMigration(from: Int)
    /// The migration from this version threw. The file is left untouched (Ruling R72).
    case migrationFailed(from: Int, underlying: String)
}

/// A JSON file holding `{"schemaVersion": n, "payload": {...}}`, written atomically and migrated
/// forward on load. Holds `config.json` and `state.json`. The payload must encode to a JSON object.
///
/// Before a file at an older version is first rewritten at the current one, it is copied, byte for
/// byte, to `<name>.v<n>.bak` beside it (mode 0600), so the user's settings as they were survive a
/// migration that turns out wrong (Ruling R72). If that copy can't be made, the file isn't rewritten.
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
        guard let existing = try readExisting() else { return nil }
        if existing.migrated { try write(existing.payload, replacing: existing) }
        return existing.payload
    }

    /// Replaces the file atomically: the data is written to a temporary file and renamed over the
    /// old one, so a failure leaves the previous file intact. An existing file that `load()` would
    /// refuse (newer schema, corrupt, no migration) is never overwritten: the same error is thrown.
    public func save(_ payload: Payload) throws {
        try write(payload, replacing: try readExisting())
    }

    /// Where a file at `version` is kept before it is migrated: `config.json.v1.bak`.
    public static func backupURL(for fileURL: URL, version: Int) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).v\(version).bak")
    }

    private struct Existing {
        var payload: Payload
        var version: Int
        var data: Data
        var migrated: Bool { version < currentVersion }
        let currentVersion: Int
    }

    /// Writes `payload`, first keeping the file it replaces when that file is at an older version.
    private func write(_ payload: Payload, replacing existing: Existing?) throws {
        if let existing, existing.migrated {
            let backup = Self.backupURL(for: fileURL, version: existing.version)
            // An earlier copy (from a rewrite that then failed) is the same file and is replaced; anything
            // that isn't a plain file is never touched.
            let type = (try? FileManager.default.attributesOfItem(atPath: backup.path))?[.type] as? FileAttributeType
            guard type == nil || type == .typeRegular,
                FileManager.default.createFile(
                    atPath: backup.path, contents: existing.data, attributes: [.posixPermissions: 0o600])
            else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: backup.path])
            }
        }
        try write(payload)
    }

    /// Reads, validates and migrates the file in memory. Nil when there is no file. Never writes.
    private func readExisting() throws -> Existing? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)

        // Check the version before the rest of the envelope, so a newer file whose shape has
        // changed is still reported as newer rather than corrupt.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["schemaVersion"] as? Int
        else {
            throw VersionedStoreError.corrupt(underlying: "Expected an object with a schemaVersion.")
        }
        guard version <= currentVersion else {
            throw VersionedStoreError.newerSchema(found: version, supported: currentVersion)
        }
        guard version >= 1 else {
            throw VersionedStoreError.corrupt(underlying: "Invalid schemaVersion \(version).")
        }
        guard var payload = root["payload"] as? [String: Any] else {
            throw VersionedStoreError.corrupt(underlying: "Expected payload to be an object.")
        }

        for from in version..<currentVersion {
            guard let migrate = migrations[from] else {
                throw VersionedStoreError.missingMigration(from: from)
            }
            do {
                try migrate(&payload)
            } catch {
                throw VersionedStoreError.migrationFailed(from: from, underlying: String(describing: error))
            }
        }

        do {
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try Self.makeDecoder().decode(Payload.self, from: payloadData)
            return Existing(payload: decoded, version: version, data: data, currentVersion: currentVersion)
        } catch {
            throw VersionedStoreError.corrupt(underlying: String(describing: error))
        }
    }

    private func write(_ payload: Payload) throws {
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

    /// Formats the whole seconds with the system formatter and appends the rounded millisecond part
    /// by hand: the formatter truncates (`...00.123` becomes `.122`).
    private static func iso8601String(_ date: Date) -> String {
        let totalMillis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Double(totalMillis.floorDiv(1000))
        let millis = totalMillis - Int64(seconds) * 1000
        var base = Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle())
        base.removeLast()  // the trailing Z
        return base + "." + String(format: "%03d", Int(millis)) + "Z"
    }

    /// ISO 8601 in UTC with fractional seconds (millisecond precision), e.g. `2027-01-15T08:00:00.123Z`.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601String(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Accepts ISO 8601 with or without fractional seconds.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                // The parser truncates; round to the millisecond so values round-trip exactly.
                return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
            }
            do {
                return try Date(string, strategy: Date.ISO8601FormatStyle())
            } catch {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(string)"
                ))
            }
        }
        return decoder
    }
}

private extension Int64 {
    func floorDiv(_ d: Int64) -> Int64 {
        let q = self / d
        return (self % d != 0 && (self < 0) != (d < 0)) ? q - 1 : q
    }
}
