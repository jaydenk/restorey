import Foundation
import os
import Synchronization

/// A rolling log (`agent.log` or `app.log`) under the logs root. Lines are redacted, stamped in UTC,
/// written to disk and mirrored to `os_log` under the subsystem `Identity.rootID`.
///
/// When a write would take the file past `maxBytes` (10 MB by default) the files rotate:
/// `.4` becomes `.5` (the old `.5` is dropped), and so on down to `.log` becoming `.1`.
public struct AppLog: Sendable {
    public enum Kind: String, Sendable {
        case agent, app
        var fileName: String { "\(rawValue).log" }
    }

    public static let defaultMaxBytes = 10 * 1024 * 1024
    public static let rotatedFileCount = 5

    private let sink: Sink
    private let logger: Logger
    private let redactor: Redactor

    /// - Parameters:
    ///   - subsystem: the `os_log` subsystem; pass `Identity.rootID`, never a literal.
    ///   - maxBytes: injectable so tests need not write 10 MB.
    public init(
        root: URL, kind: Kind, subsystem: String,
        redactor: Redactor = Redactor(secrets: []), maxBytes: Int = AppLog.defaultMaxBytes
    ) {
        sink = Sink(root: root, fileName: kind.fileName, maxBytes: maxBytes)
        logger = Logger(subsystem: subsystem, category: kind.rawValue)
        self.redactor = redactor
    }

    public init(identity: Identity, kind: Kind, redactor: Redactor = Redactor(secrets: [])) {
        self.init(
            root: identity.logsDirectory(), kind: kind, subsystem: identity.rootID, redactor: redactor)
    }

    public func info(_ s: String) {
        let text = redactor.redact(s)
        write(level: "INFO", text)
        logger.info("\(text, privacy: .public)")
    }

    public func error(_ s: String) {
        let text = redactor.redact(s)
        write(level: "ERROR", text)
        logger.error("\(text, privacy: .public)")
    }

    private func write(level: String, _ text: String) {
        let stamp = LogFiles.lineTimestamp(Date())
        let data = Data(
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\(stamp) \(level) \($0)\n" }.joined().utf8)
        sink.append(data)
    }

    private final class Sink: Sendable {
        private struct State {
            var handle: FileHandle?
            var size: Int = 0
        }

        private let root: URL
        private let fileName: String
        private let maxBytes: Int
        private let state = Mutex(State())

        init(root: URL, fileName: String, maxBytes: Int) {
            self.root = root
            self.fileName = fileName
            self.maxBytes = maxBytes
        }

        private var current: URL { root.appendingPathComponent(fileName) }

        func append(_ data: Data) {
            state.withLock { state in
                do {
                    if state.handle == nil { try open(&state) }
                    // An empty file never rotates, so one oversized line cannot loop.
                    if state.size > 0, state.size + data.count > maxBytes {
                        try? state.handle?.close()
                        state.handle = nil
                        rotate()
                        try open(&state)
                    }
                    try state.handle?.write(contentsOf: data)
                    state.size += data.count
                } catch {
                    // Logging must never take the process down; drop the line.
                    state.handle = nil
                }
            }
        }

        private func open(_ state: inout State) throws {
            try LogFiles.createPrivateDirectory(root, below: root)
            state.handle = try LogFiles.openForAppending(current)
            let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size]) as? Int
            state.size = size ?? 0
        }

        private func rotate() {
            let fm = FileManager.default
            func rotated(_ n: Int) -> URL { root.appendingPathComponent("\(fileName).\(n)") }
            try? fm.removeItem(at: rotated(AppLog.rotatedFileCount))
            for n in stride(from: AppLog.rotatedFileCount - 1, through: 1, by: -1) {
                try? fm.moveItem(at: rotated(n), to: rotated(n + 1))
            }
            try? fm.moveItem(at: current, to: rotated(1))
        }
    }
}
