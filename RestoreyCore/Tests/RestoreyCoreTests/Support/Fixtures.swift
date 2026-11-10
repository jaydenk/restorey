import Foundation

/// Captured restic output stored in `Tests/RestoreyCoreTests/Fixtures`. A missing fixture is a
/// test failure, never a skip.
enum Fixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .appendingPathComponent("../Fixtures/\(name)")
            .standardized
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    /// The non-empty lines of an NDJSON fixture.
    static func lines(_ name: String) throws -> [String] {
        try text(name).split(whereSeparator: \.isNewline).map(String.init)
    }
}
