import Foundation

/// Schema history for `config.json`. `VersionedStore` runs `migrations[n]` to take a payload from
/// version `n` to `n + 1`, working on the decoded dictionary so old shapes never need old Swift types.
public enum ConfigMigrations {
    public static let currentVersion = 1

    public static let migrations: [Int: @Sendable (inout [String: Any]) throws -> Void] = [:]
}
