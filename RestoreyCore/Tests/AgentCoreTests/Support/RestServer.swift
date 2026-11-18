import Foundation

/// A local rest-server on a free 127.0.0.1 port, with no authentication, storing into `directory`.
/// Always `stop()` it in a `defer`.
///
/// (A copy of RestoreyCoreTests' `RestServer`; test targets can't depend on one another.)
final class RestServer: @unchecked Sendable {
    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "rest-server not found at \(path). Run scripts/fetch-binaries.sh or set REST_SERVER_BINARY."
        }
    }

    let port: Int
    let directory: URL
    private let process = Process()

    var repository: String { "rest:http://127.0.0.1:\(port)/" }

    private init(directory: URL) throws {
        self.directory = directory
        port = try Self.freeLocalPort()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = try Self.binary()
        process.arguments = ["--listen", "127.0.0.1:\(port)", "--path", directory.path, "--no-auth"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Starts the server and returns once it accepts connections. Waits with `Task.sleep`, never by
    /// blocking a cooperative thread (Ruling R71).
    static func start(directory: URL) async throws -> RestServer {
        let server = try RestServer(directory: directory)
        for _ in 0..<100 {
            guard server.process.isRunning else { throw POSIXError(.ECONNREFUSED) }
            if server.canConnect() { return server }
            try await Task.sleep(for: .milliseconds(50))
        }
        server.stop()
        throw POSIXError(.ETIMEDOUT)
    }

    /// Kills the server. Foundation reaps it; nothing waits here.
    func stop() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    /// The vendored rest-server, or `REST_SERVER_BINARY`. Missing is a failure, never a skip.
    private static func binary() throws -> URL {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["REST_SERVER_BINARY"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            // <repo>/RestoreyCore/Tests/AgentCoreTests/Support/RestServer.swift -> <repo>/vendor/rest-server
            url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("vendor/rest-server")
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw Missing(path: url.path) }
        return url
    }

    private func canConnect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = Self.loopback(port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }

    /// A port nothing is listening on: bound to port 0, read back, released.
    private static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
