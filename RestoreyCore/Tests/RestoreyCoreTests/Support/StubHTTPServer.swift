import Foundation
import Network
import Synchronization

/// A minimal HTTP/1.1 server on 127.0.0.1 and a free port, for tests only. It reads the request line,
/// the headers and a `Content-Length` body, records each request, and answers with the next scripted
/// reply (a status code with an empty body, or no reply at all), then closes the connection. Once the
/// script runs out it answers 200. Always `stop()` it in a `defer`.
final class StubHTTPServer: Sendable {
    enum Reply: Sendable {
        case status(Int)
        /// Never answer and never close: the client has to time out.
        case hang
    }

    struct Request: Sendable, Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct StartFailure: Error {}

    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)" }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "StubHTTPServer")
    private let state = Shared()

    private struct State {
        var script: [Reply] = []
        var requests: [Request] = []
        var connections: [NWConnection] = []
    }

    /// The state behind a reference, so the listener's callbacks can share it.
    private final class Shared: Sendable {
        private let mutex = Mutex(State())
        func withLock<T>(_ body: (inout State) -> T) -> T { mutex.withLock { body(&$0) } }
    }

    init(script: [Reply] = []) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        state.withLock { $0.script = script }

        let ready = DispatchSemaphore(value: 0)
        let failed = Mutex(false)
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .ready: ready.signal()
            case .failed, .cancelled:
                failed.withLock { $0 = true }
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [state, queue] connection in
            state.withLock { $0.connections.append(connection) }
            connection.start(queue: queue)
            Self.receive(on: connection, buffer: Data(), state: state)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, !failed.withLock({ $0 }),
            let port = listener.port?.rawValue
        else {
            listener.cancel()
            throw StartFailure()
        }
        self.port = port
    }

    /// Every request received so far, in order of arrival.
    var requests: [Request] { state.withLock { $0.requests } }

    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }

    // MARK: Parsing

    private static func receive(on connection: NWConnection, buffer: Data, state: Shared) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                respond(to: request, on: connection, state: state)
            } else if error == nil, !isComplete {
                receive(on: connection, buffer: buffer, state: state)
            } else {
                connection.cancel()
            }
        }
    }

    /// The request once the headers and the whole body have arrived; nil while more is needed.
    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: buffer[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
            body: Data(body.prefix(length)))
    }

    private static func respond(to request: Request, on connection: NWConnection, state: Shared) {
        let reply = state.withLock { state -> Reply in
            state.requests.append(request)
            return state.script.isEmpty ? .status(200) : state.script.removeFirst()
        }
        guard case .status(let code) = reply else { return }
        let response = "HTTP/1.1 \(code) Stub\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
