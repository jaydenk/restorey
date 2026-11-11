import Foundation

/// A local rest-server on a free 127.0.0.1 port, with no authentication, storing into `directory`.
/// Always `stop()` it in a `defer`.
final class RestServer: @unchecked Sendable {
    let port: Int
    let directory: URL
    private let process = Process()

    var repository: String { "rest:http://127.0.0.1:\(port)/" }

    /// - Parameter authentication: leave off for an open server; on, only `.htpasswd` users get in.
    private init(directory: URL, authentication: Bool) throws {
        self.directory = directory
        port = try freeLocalPort()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = try TestBinaries.requireRestServer()
        process.arguments = ["--listen", "127.0.0.1:\(port)", "--path", directory.path]
            + (authentication ? [] : ["--no-auth"])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Starts the server and returns once it accepts connections. Waits with `Task.sleep`, never by
    /// blocking a cooperative thread (Ruling R71).
    static func start(directory: URL, authentication: Bool = false) async throws -> RestServer {
        let server = try RestServer(directory: directory, authentication: authentication)
        for _ in 0..<100 {
            guard server.process.isRunning else { throw POSIXError(.ECONNREFUSED) }
            if server.canConnect() { return server }
            try await Task.sleep(for: .milliseconds(50))
        }
        server.stop()
        throw POSIXError(.ETIMEDOUT)
    }

    private func canConnect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// Kills the server. Foundation reaps it; nothing waits here.
    func stop() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
