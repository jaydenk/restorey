import Foundation

/// A local rest-server on a free 127.0.0.1 port, with no authentication, storing into `directory`.
/// Always `stop()` it in a `defer`.
final class RestServer: @unchecked Sendable {
    let port: Int
    let directory: URL
    private let process = Process()

    var repository: String { "rest:http://127.0.0.1:\(port)/" }

    /// - Parameter authentication: leave off for an open server; on, only `.htpasswd` users get in.
    init(directory: URL, authentication: Bool = false) throws {
        self.directory = directory
        port = try freeLocalPort()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = try TestBinaries.requireRestServer()
        process.arguments = ["--listen", "127.0.0.1:\(port)", "--path", directory.path]
            + (authentication ? [] : ["--no-auth"])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try waitUntilListening()
    }

    private func waitUntilListening() throws {
        for _ in 0..<100 {
            guard process.isRunning else { throw POSIXError(.ECONNREFUSED) }
            if canConnect() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
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

    func stop() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
