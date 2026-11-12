import Foundation
import os
import Synchronization

/// A rolling log (`agent.log` or `app.log`) under the logs root. Lines are redacted, stamped in UTC,
/// written to disk and mirrored to `os_log` under the subsystem `Identity.rootID`.
///
/// When a write would take the file past `maxBytes` (10 MB by default) the files rotate:
/// `.4` becomes `.5` (the old `.5` is dropped), and so on down to `.log` becoming `.1`.
///
/// There is one sink per file path per process, shared by every `AppLog` for that file, so two
/// instances never rotate over each other. Before each write the sink checks that its open file is
/// still the one at the path (same device and inode) and reopens if the file was rotated, deleted or
/// replaced by someone else.
///
/// A logging failure never throws. It is counted in `droppedLineCount` and the first one is reported
/// once through `os_log` (category `logging`), naming the file and error but never the line.
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
    ///   - maxBytes: injectable so tests need not write 10 MB. The first `AppLog` created for a file
    ///     in this process decides it.
    public init(
        root: URL, kind: Kind, subsystem: String,
        redactor: Redactor = Redactor(secrets: []), maxBytes: Int = AppLog.defaultMaxBytes
    ) {
        sink = Sink.shared(
            root: root, fileName: kind.fileName, maxBytes: maxBytes, subsystem: subsystem)
        logger = Logger(subsystem: subsystem, category: kind.rawValue)
        self.redactor = redactor
    }

    public init(identity: Identity, kind: Kind, redactor: Redactor = Redactor(secrets: [])) {
        self.init(
            root: identity.logsDirectory(), kind: kind, subsystem: identity.rootID, redactor: redactor)
    }

    /// How many lines could not be written to disk.
    public var droppedLineCount: Int { sink.droppedLineCount }
    public var hadWriteFailure: Bool { droppedLineCount > 0 }

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
            var dropped = 0
            var rotationBlocked = false
        }

        private static let registry = Mutex<[String: Sink]>([:])

        static func shared(root: URL, fileName: String, maxBytes: Int, subsystem: String) -> Sink {
            let key = root.standardizedFileURL.appendingPathComponent(fileName).path
            return registry.withLock { registry in
                if let existing = registry[key] { return existing }
                let sink = Sink(root: root, fileName: fileName, maxBytes: maxBytes, subsystem: subsystem)
                registry[key] = sink
                return sink
            }
        }

        private let root: URL
        private let fileName: String
        private let maxBytes: Int
        private let logger: Logger
        private let state = Mutex(State())

        private init(root: URL, fileName: String, maxBytes: Int, subsystem: String) {
            self.root = root
            self.fileName = fileName
            self.maxBytes = maxBytes
            logger = Logger(subsystem: subsystem, category: "logging")
        }

        private var current: URL { root.appendingPathComponent(fileName) }

        var droppedLineCount: Int { state.withLock { $0.dropped } }

        func append(_ data: Data) {
            var problems: [String] = []
            state.withLock { state in
                do {
                    try ensureCurrent(&state)
                    if let handle = state.handle, !state.rotationBlocked,
                       let size = Self.size(of: handle), size > 0, size + data.count > maxBytes
                    {
                        // An empty file never rotates, so one oversized line cannot loop.
                        if rotate() {
                            try? handle.close()
                            state.handle = nil
                            try ensureCurrent(&state)
                        } else {
                            // Do not reopen or retry: keep appending to the oversized file.
                            state.rotationBlocked = true
                            problems.append("could not rotate \(fileName); continuing to append to it")
                        }
                    }
                    try state.handle?.write(contentsOf: data)
                } catch {
                    state.handle = nil
                    state.dropped += 1
                    if state.dropped == 1 {
                        problems.append("write to \(current.path) failed: \(error.localizedDescription)")
                    }
                }
            }
            for problem in problems { logger.error("App log: \(problem, privacy: .public)") }
        }

        /// Opens the file if needed, and reopens if the path no longer refers to the open file.
        private func ensureCurrent(_ state: inout State) throws {
            if let handle = state.handle {
                if Self.sameFile(handle, as: current) { return }
                try? handle.close()
                state.handle = nil
            }
            if !FileManager.default.fileExists(atPath: root.path) {
                try LogFiles.createPrivateDirectory(root, below: root)
            }
            state.handle = try LogFiles.open(current)
        }

        private static func size(of handle: FileHandle) -> Int? {
            var info = stat()
            return fstat(handle.fileDescriptor, &info) == 0 ? Int(info.st_size) : nil
        }

        private static func sameFile(_ handle: FileHandle, as url: URL) -> Bool {
            var open = stat(), path = stat()
            guard fstat(handle.fileDescriptor, &open) == 0, stat(url.path, &path) == 0 else { return false }
            return open.st_dev == path.st_dev && open.st_ino == path.st_ino
        }

        /// Returns false if the current file could not be moved aside.
        private func rotate() -> Bool {
            let fm = FileManager.default
            func rotated(_ n: Int) -> URL { root.appendingPathComponent("\(fileName).\(n)") }
            try? fm.removeItem(at: rotated(AppLog.rotatedFileCount))
            for n in stride(from: AppLog.rotatedFileCount - 1, through: 1, by: -1) {
                try? fm.moveItem(at: rotated(n), to: rotated(n + 1))
            }
            do {
                try fm.moveItem(at: current, to: rotated(1))
                return true
            } catch {
                return false
            }
        }
    }
}
