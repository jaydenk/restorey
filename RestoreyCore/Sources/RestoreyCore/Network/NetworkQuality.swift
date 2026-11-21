import Foundation

/// An upload result read from `networkQuality -c`, before it is stamped with a time.
public struct UploadSpeedMeasurementDraft: Sendable, Equatable {
    public var bitsPerSecond: Double
    public var bytesSent: Int64?

    public init(bitsPerSecond: Double, bytesSent: Int64?) {
        self.bitsPerSecond = bitsPerSecond
        self.bytesSent = bytesSent
    }
}

/// Why an upload speed test gave no result. `message` is the sentence shown to the user, with no closing full stop.
public enum SpeedTestError: Error, Equatable, Sendable {
    case couldNotStart(String)
    case timedOut
    case exited(Int32)
    case unreadable
    case noUploadMeasured

    public var message: String {
        switch self {
        case .couldNotStart(let reason): "The upload speed test couldn’t start: \(reason)"
        case .timedOut: "The upload speed test didn’t finish in time"
        case .exited(let code): "The upload speed test stopped with an error (\(code))"
        case .unreadable: "The upload speed test’s result couldn’t be read"
        case .noUploadMeasured: "The upload speed test didn’t measure any upload"
        }
    }
}

/// Runs macOS's `networkQuality` for its upload speed. Deliberately not `ResticProcess`, which is restic-specific.
public enum NetworkQuality {
    public static let executable = URL(fileURLWithPath: "/usr/bin/networkQuality")
    /// Upload only, JSON, a 20 second bound on the test itself.
    public static let arguments = ["-d", "-c", "-M", "20"]
    /// How long after `terminate()` a run that hasn't ended is sent SIGKILL.
    public static let killAfter: Duration = .seconds(10)
    /// The test's own bound (`-M 20`) plus time to start and report.
    public static let defaultBound: Duration = .seconds(20 + 5)

    /// Reads `ul_throughput` (bits per second) and `ul_bytes_transferred` from the tool's JSON. A missing,
    /// null, non-finite or non-positive throughput is `noUploadMeasured`; a throughput that isn't a number, or
    /// output that isn't a JSON object, is `unreadable`. Neither is ever returned as a speed.
    public static func parse(stdout: Data) -> Result<UploadSpeedMeasurementDraft, SpeedTestError> {
        guard let root = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else {
            return .failure(.unreadable)
        }
        guard let rawThroughput = root["ul_throughput"], !(rawThroughput is NSNull) else {
            return .failure(.noUploadMeasured)
        }
        guard let throughput = number(rawThroughput) else { return .failure(.unreadable) }
        let bitsPerSecond = throughput.doubleValue
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return .failure(.noUploadMeasured) }
        let bytes = root["ul_bytes_transferred"].flatMap(number).flatMap { Int64(exactly: $0.doubleValue.rounded()) }
        return .success(UploadSpeedMeasurementDraft(bitsPerSecond: bitsPerSecond, bytesSent: bytes))
    }

    /// A JSON number, not a boolean or a string.
    private static func number(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    /// Runs `executable` (the real tool, or a stand-in in tests) with `arguments`, reads its JSON and stamps the
    /// result with `now()`. Past `bound` the process is sent `terminate()`, and SIGKILL `killAfter` later if it
    /// is still running, so a hung test never outlives the call. Cancelling the caller ends it the same way.
    public static func run(
        executable: URL = NetworkQuality.executable,
        now: @Sendable () -> Date,
        bound: Duration = NetworkQuality.defaultBound,
        killAfter: Duration = NetworkQuality.killAfter
    ) async -> Result<UploadSpeedMeasurement, SpeedTestError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.couldNotStart(error.localizedDescription))
        }
        let guardian = ProcessGuardian(process)
        let watchdog = Task {
            guard (try? await Task.sleep(for: bound)) != nil else { return }
            guardian.terminate(timedOut: true)
            guard (try? await Task.sleep(for: killAfter)) != nil else { return }
            guardian.kill()
        }
        let (data, status, reason) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (data, process.terminationStatus, process.terminationReason))
                }
            }
        } onCancel: {
            guardian.terminate(timedOut: false)
            Task {
                try? await Task.sleep(for: killAfter)
                guardian.kill()
            }
        }
        watchdog.cancel()

        if guardian.timedOut { return .failure(.timedOut) }
        if reason == .uncaughtSignal || status != 0 { return .failure(.exited(status)) }
        switch parse(stdout: data) {
        case .success(let draft):
            return .success(UploadSpeedMeasurement(bitsPerSecond: draft.bitsPerSecond, bytesSent: draft.bytesSent, measuredAt: now()))
        case .failure(let error):
            return .failure(error)
        }
    }
}

/// Signals a running `Process` from the watchdog while another thread waits on it.
private final class ProcessGuardian: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var didTimeOut = false

    init(_ process: Process) { self.process = process }

    var timedOut: Bool { lock.withLock { didTimeOut } }

    func terminate(timedOut: Bool) {
        lock.withLock {
            if timedOut { didTimeOut = true }
            if process.isRunning { process.terminate() }
        }
    }

    func kill() {
        lock.withLock {
            // `isRunning` is false once the process has been reaped, so a recycled pid is never signalled.
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }
    }
}
