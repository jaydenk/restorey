import Foundation
import MetricKit
import RestoreyCore

/// Keeps MetricKit's crash, hang and resource diagnostics on disk (spec §8, crash reporting from day
/// one). Each `MXDiagnosticPayload` becomes `<logs>/diagnostics/<UTC timestamp>.json`, mode 0600 in a
/// 0700 folder. Nothing leaves the Mac.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    private let directory: URL
    private let log: AppLog

    /// - Parameter directory: `Identity.logsDirectory()/diagnostics`.
    init(directory: URL, log: AppLog) {
        self.directory = directory
        self.log = log
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation()) }
    }

    private func save(_ data: Data) {
        do {
            let url = try write(data)
            log.info("Saved a MetricKit diagnostic report to \(url.path)")
        } catch {
            log.error("Couldn't save a MetricKit diagnostic report: \(error)")
        }
    }

    /// Writes to a new file, never over an existing one: a second payload in the same millisecond gets
    /// a `-1`, `-2`… suffix.
    private func write(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let stamp = Date().formatted(Date.ISO8601FormatStyle(
            dateSeparator: .omitted, timeSeparator: .omitted, includingFractionalSeconds: true, timeZone: .gmt))
        var attempt = 0
        while true {
            let name = attempt == 0 ? "\(stamp).json" : "\(stamp)-\(attempt).json"
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                if errno == EEXIST { attempt += 1; continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                unlink(url.path)
                throw error
            }
            return url
        }
    }
}
