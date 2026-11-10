import Foundation
import Synchronization
import os

/// Owns `~/Library/Logs/<logsName>/runs/<planID>/`: one log file per run, kept for 400 days so a
/// yearly restore drill can still find the run it needs.
///
/// Directories are created 0700 and files 0600, because logs hold file paths and repository names.
/// Every line is redacted before it is written.
public actor RunLogStore {
    /// Long enough for a yearly restore drill (spec: run logs).
    public static let defaultRetention: TimeInterval = 400 * 86_400

    private let root: URL
    private let subsystem: String
    private let logger: Logger
    private var runsDirectory: URL { root.appendingPathComponent("runs", isDirectory: true) }

    /// - Parameter subsystem: the `os_log` subsystem for the store's own problems; pass `Identity.rootID`.
    public init(root: URL, subsystem: String) {
        self.root = root
        self.subsystem = subsystem
        logger = Logger(subsystem: subsystem, category: "logging")
    }

    public init(identity: Identity) {
        self.init(root: identity.logsDirectory(), subsystem: identity.rootID)
    }

    /// Creates `runs/<planID>/<yyyyMMdd'T'HHmmss'Z'>-<operation slug>.log` (UTC) and returns its writer.
    /// If that name is taken (another run of the same plan and operation started in the same second)
    /// the file is `...-<slug>-2.log`, then `-3`, and so on. An existing log is never reused.
    public func begin(
        planID: UUID, operation: ResticOperation, startedAt: Date, redactor: Redactor
    ) throws -> RunLogWriter {
        let planDirectory = runsDirectory.appendingPathComponent(planID.uuidString, isDirectory: true)
        try LogFiles.createPrivateDirectory(planDirectory, below: root)
        let stem = "\(LogFiles.fileTimestamp(startedAt))-\(operation.logSlug)"
        for attempt in 1...1_000 {
            let file = planDirectory.appendingPathComponent(attempt == 1 ? "\(stem).log" : "\(stem)-\(attempt).log")
            do {
                let handle = try LogFiles.open(file, exclusive: true)
                return RunLogWriter(file: file, handle: handle, redactor: redactor, subsystem: subsystem)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                continue
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST),
                      userInfo: [NSFilePathErrorKey: planDirectory.path])
    }

    /// Removes run logs last modified more than `retention` before `now`, then any empty plan folders.
    /// Touches nothing outside `runs/`. A file that cannot be removed is skipped (and logged once);
    /// the count is of files actually removed.
    @discardableResult
    public func prune(now: Date, retention: TimeInterval = RunLogStore.defaultRetention) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runsDirectory.path) else { return 0 }
        let cutoff = now.addingTimeInterval(-retention)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        var removed = 0
        var reportedFailure = false

        for planDirectory in try fm.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: keys)
        {
            // Plain directories only: never follow a symlink out of runs/.
            guard (try? planDirectory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  (try? planDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { continue }

            for file in (try? fm.contentsOfDirectory(at: planDirectory, includingPropertiesForKeys: keys)) ?? [] {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified < cutoff
                else { continue }
                do {
                    try fm.removeItem(at: file)
                    removed += 1
                } catch {
                    if !reportedFailure {
                        reportedFailure = true
                        logger.error(
                            "Pruning run logs failed to remove \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            if (try? fm.contentsOfDirectory(atPath: planDirectory.path))?.isEmpty == true {
                try? fm.removeItem(at: planDirectory)
            }
        }
        return removed
    }
}

/// Appends redacted, UTC-timestamped lines to one run's log. Safe to call from several threads:
/// restic's stdout and stderr drains write concurrently.
///
/// A failed write never throws, because a logging problem must not fail a backup. It is counted in
/// `droppedLineCount` (the plan runner records it) and the first failure is logged once to `os_log`.
public final class RunLogWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        var dropped = 0
    }

    private let redactor: Redactor
    private let state: Mutex<State>
    private let logger: Logger
    public let fileURL: URL

    fileprivate init(file: URL, handle: FileHandle, redactor: Redactor, subsystem: String) {
        self.redactor = redactor
        self.fileURL = file
        logger = Logger(subsystem: subsystem, category: "logging")
        state = Mutex(State(handle: handle))
    }

    /// How many lines could not be written.
    public var droppedLineCount: Int { state.withLock { $0.dropped } }
    public var hadWriteFailure: Bool { droppedLineCount > 0 }

    /// Redacts `s`, then writes it as one line per embedded newline, each stamped with the current
    /// UTC time. Ignored after `close()`.
    public func line(_ s: String) {
        let text = redactor.redact(s)
        let stamp = LogFiles.lineTimestamp(Date())
        let data = Data(
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\(stamp) \($0)\n" }.joined().utf8)
        let failure: String? = state.withLock { state in
            guard let handle = state.handle else { return nil }
            do {
                try handle.write(contentsOf: data)
                return nil
            } catch {
                state.dropped += 1
                // Report the first failure only. The description names the file and errno, never the line.
                return state.dropped == 1 ? error.localizedDescription : nil
            }
        }
        if let failure {
            logger.error(
                "Run log write failed for \(self.fileURL.path, privacy: .public): \(failure, privacy: .public)")
        }
    }

    public func close() {
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }

    /// Closes the descriptor but keeps the handle, so the next write fails like a broken disk would.
    func breakDescriptorForTesting() {
        state.withLock { try? $0.handle?.close() }
    }
}

/// File-system and timestamp helpers shared by the run logs and the app log.
enum LogFiles {
    /// Creates `directory` (and anything missing up to it) with mode 0700, and sets 0700 on every
    /// directory from `root` down. Directories above `root` are left as they are.
    static func createPrivateDirectory(_ directory: URL, below root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var current = directory.standardizedFileURL
        let top = root.standardizedFileURL
        while current.path.hasPrefix(top.path) {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            if current == top { break }
            current = current.deletingLastPathComponent()
        }
    }

    /// Opens (creating at 0600 if needed) for appending. `O_APPEND` means concurrent writers never
    /// overwrite each other. With `exclusive` the call fails with EEXIST rather than reuse a file.
    static func open(_ file: URL, exclusive: Bool = false) throws -> FileHandle {
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | (exclusive ? O_EXCL : 0)
        let fd = Darwin.open(file.path, flags, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: file.path])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// `20261110T010203Z`
    static func fileTimestamp(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted, timeZone: .gmt))
    }

    /// `2026-11-10T01:02:03.456Z`
    static func lineTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }
}
