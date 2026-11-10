import Foundation

/// Locations of the vendored upstream binaries used by integration tests.
/// A missing binary is a test failure, never a skip: a skipped test would hide a broken fetch.
enum TestBinaries {
    enum Missing: Error, CustomStringConvertible {
        case notFound(name: String, path: String)
        var description: String {
            switch self {
            case let .notFound(name, path):
                "\(name) not found at \(path). Run scripts/fetch-binaries.sh or set the environment override."
            }
        }
    }

    static var restic: URL { locate("restic", override: "RESTIC_BINARY") }
    static var restServer: URL { locate("rest-server", override: "REST_SERVER_BINARY") }

    /// Throws when the binary is absent, so tests call this and fail loudly.
    static func requireRestic() throws -> URL { try require(restic, name: "restic") }
    static func requireRestServer() throws -> URL { try require(restServer, name: "rest-server") }

    private static func require(_ url: URL, name: String) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Missing.notFound(name: name, path: url.path)
        }
        return url
    }

    private static func locate(_ name: String, override: String) -> URL {
        if let path = ProcessInfo.processInfo.environment[override], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return repoRoot.appendingPathComponent("vendor").appendingPathComponent(name)
    }

    /// <repo>/RestoreyCore/Tests/RestoreyCoreTests/Support/TestBinaries.swift -> <repo>
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // RestoreyCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RestoreyCore
            .deletingLastPathComponent() // repo
    }
}
