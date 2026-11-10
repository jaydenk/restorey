import Foundation
import Synchronization

/// Owns `~/Library/Logs/<logsName>/runs/<planID>/`: one log file per run, kept for 400 days so a
/// yearly restore drill can still find the run it needs.
///
/// Directories are created 0700 and files 0600, because logs hold file paths and repository names.
/// Every line is redacted before it is written.
public actor RunLogStore {
    /// Long enough for a yearly restore drill (spec: run logs).
    public static let defaultRetention: TimeInterval = 400 * 86_400

    private let root: URL
    private var runsDirectory: URL { root.appendingPathComponent("runs", isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    /// Creates `runs/<planID>/<yyyyMMdd'T'HHmmss'Z'>-<operation slug>.log` (UTC) and returns its writer.
    public func begin(
        planID: UUID, operation: ResticOperation, startedAt: Date, redactor: Redactor
    ) throws -> RunLogWriter {
        let planDirectory = runsDirectory.appendingPathComponent(planID.uuidString, isDirectory: true)
        try LogFiles.createPrivateDirectory(planDirectory, below: root)
        let name = "\(LogFiles.fileTimestamp(startedAt))-\(operation.logSlug).log"
        return try RunLogWriter(
            file: planDirectory.appendingPathComponent(name), redactor: redactor)
    }

    /// Removes run logs last modified more than `retention` before `now`, then any empty plan folders.
    /// Touches nothing outside `runs/`. Returns the number of files removed.
    @discardableResult
    public func prune(now: Date, retention: TimeInterval = RunLogStore.defaultRetention) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runsDirectory.path) else { return 0 }
        let cutoff = now.addingTimeInterval(-retention)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        var removed = 0

        for planDirectory in try fm.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: keys)
        {
            // Plain directories only: never follow a symlink out of runs/.
            guard (try? planDirectory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  (try? planDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { continue }

            for file in try fm.contentsOfDirectory(at: planDirectory, includingPropertiesForKeys: keys) {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified < cutoff
                else { continue }
                try fm.removeItem(at: file)
                removed += 1
            }
            if try fm.contentsOfDirectory(atPath: planDirectory.path).isEmpty {
                try fm.removeItem(at: planDirectory)
            }
        }
        return removed
    }
}

/// Appends redacted, UTC-timestamped lines to one run's log. Safe to call from several threads:
/// restic's stdout and stderr drains write concurrently.
public final class RunLogWriter: Sendable {
    private let redactor: Redactor
    private let handle: Mutex<FileHandle?>
    public let fileURL: URL

    fileprivate init(file: URL, redactor: Redactor) throws {
        self.redactor = redactor
        self.fileURL = file
        handle = Mutex(try LogFiles.openForAppending(file))
    }

    /// Redacts `s`, then writes it as one line per embedded newline, each stamped with the current
    /// UTC time. Ignored after `close()`. A failed write is dropped rather than failing the run.
    public func line(_ s: String) {
        let text = redactor.redact(s)
        let stamp = LogFiles.lineTimestamp(Date())
        let data = Data(
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\(stamp) \($0)\n" }.joined().utf8)
        handle.withLock { file in
            try? file?.write(contentsOf: data)
        }
    }

    public func close() {
        handle.withLock { file in
            try? file?.close()
            file = nil
        }
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

    /// Opens (creating at 0600 if needed) for appending. `O_APPEND` means concurrent writers and a
    /// second run in the same second never overwrite each other.
    static func openForAppending(_ file: URL) throws -> FileHandle {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
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
