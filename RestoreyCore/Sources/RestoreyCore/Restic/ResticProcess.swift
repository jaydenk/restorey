import Foundation

/// How a restic process ended. Feed the fields to `classify`.
public struct ResticTermination: Sendable, Equatable {
    /// restic's exit status. When the process was ended by a signal this is `128 + signal`, the shell
    /// convention, and `terminatedBySignal` says which.
    public var exitCode: Int32
    /// Set when the process died from a signal rather than exiting, for example SIGKILL after an
    /// interrupt that restic did not honour in time.
    public var terminatedBySignal: Int32?
    /// What we asked for with `interrupt`, if we did. The last request wins.
    public var interruptIntent: InterruptIntent?
    /// The text of the last `exit_error` message restic printed.
    public var exitErrorMessage: String?
    /// The last 20 lines restic wrote to stderr, as written.
    public var stderrTail: [String]
    /// Every `error` message, in the order they arrived on stderr.
    public var messages: [ResticItemError]
    public var summary: BackupSummary?
    public var pid: pid_t

    public init(
        exitCode: Int32, terminatedBySignal: Int32? = nil, interruptIntent: InterruptIntent? = nil,
        exitErrorMessage: String? = nil, stderrTail: [String] = [], messages: [ResticItemError] = [],
        summary: BackupSummary? = nil, pid: pid_t
    ) {
        self.exitCode = exitCode
        self.terminatedBySignal = terminatedBySignal
        self.interruptIntent = interruptIntent
        self.exitErrorMessage = exitErrorMessage
        self.stderrTail = stderrTail
        self.messages = messages
        self.summary = summary
        self.pid = pid
    }
}

public enum ResticProcessError: Error, Equatable {
    /// A `ResticProcess` runs once. Make another for the next run.
    case alreadyStarted
}

/// Runs one restic process and reports what it printed and how it ended. This is the only way the
/// agent runs restic.
///
/// - The child gets exactly `invocation.environment` plus `HOME` and `PATH=/usr/bin:/bin`. Nothing is
///   inherited from the agent, so its own environment (and anything in it) never reaches restic.
/// - stdout and stderr are drained concurrently, off the actor, until both reach end of file. `run`
///   returns only after the process has exited and both streams are fully read, so a trailing
///   summary line is never lost.
/// - `onMessage` is called from the two reader tasks, in order within a stream but with no ordering
///   between the streams, and may be called concurrently.
public actor ResticProcess {
    private let executable: URL
    private let invocation: ResticInvocation
    private let planID: UUID
    private let supervisor: SupervisedProcesses
    private let homeDirectory: URL

    private var process: Process?
    private var started = false
    private var exited = false
    private var intent: InterruptIntent?

    /// - Parameters:
    ///   - planID: the plan this run belongs to, recorded in `supervisor` while the process lives.
    ///   - homeDirectory: becomes the child's `HOME`.
    public init(
        executable: URL, invocation: ResticInvocation, planID: UUID,
        supervisor: SupervisedProcesses = .shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.executable = executable
        self.invocation = invocation
        self.planID = planID
        self.supervisor = supervisor
        self.homeDirectory = homeDirectory
    }

    public func run(onMessage: @escaping @Sendable (ResticMessage) -> Void) async throws -> ResticTermination {
        guard !started else { throw ResticProcessError.alreadyStarted }
        started = true

        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        // Restic's own variables first, so HOME and PATH below cannot be replaced by them.
        var environment = invocation.environment
        environment["HOME"] = homeDirectory.path
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        process.qualityOfService = .utility
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        // Set before `run()`, so an immediate exit is still seen.
        let (exitEvents, exitSignal) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            exitSignal.yield()
            exitSignal.finish()
        }

        try process.run()
        // The parent's copies of the write ends must close or the readers never see end of file.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let pid = process.processIdentifier
        self.process = process
        await supervisor.insert(pid: pid, planID: planID)

        async let out = Self.drain(stdout.fileHandleForReading, onMessage: onMessage)
        async let err = Self.drain(stderr.fileHandleForReading, onMessage: onMessage)
        for await _ in exitEvents {}
        let stdoutResult = await out
        let stderrResult = await err

        exited = true
        await supervisor.remove(pid: pid)

        let signalled = process.terminationReason == .uncaughtSignal
        let status = process.terminationStatus
        return ResticTermination(
            exitCode: signalled ? 128 + status : status,
            terminatedBySignal: signalled ? status : nil,
            interruptIntent: intent,
            exitErrorMessage: stderrResult.exitErrorMessage ?? stdoutResult.exitErrorMessage,
            stderrTail: stderrResult.tail,
            messages: stderrResult.errors + stdoutResult.errors,
            summary: stdoutResult.summary ?? stderrResult.summary,
            pid: pid
        )
    }

    /// Asks restic to stop with SIGINT, and kills it with SIGKILL if it is still running after
    /// `killAfter`. Returns at once; the kill is sent later from a background task. A call before the
    /// process has started, or after it has exited, does nothing. The last intent given is reported.
    public func interrupt(_ intent: InterruptIntent, killAfter: Duration = .seconds(10)) {
        guard let process, !exited, process.isRunning else { return }
        self.intent = intent
        kill(process.processIdentifier, SIGINT)
        Task { [weak self] in
            try? await Task.sleep(for: killAfter)
            await self?.killIfStillRunning()
        }
    }

    private func killIfStillRunning() {
        guard let process, !exited, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private struct Drained: Sendable {
        var tail: [String] = []
        var errors: [ResticItemError] = []
        var summary: BackupSummary?
        var exitErrorMessage: String?
    }

    private static let tailLength = 20

    /// Reads `handle` to end of file, parsing every line. The blocking `read` calls run on a dedicated
    /// dispatch queue for this stream, so neither stream waits for the other and nothing blocks the
    /// actor or the cooperative thread pool. (`FileHandle.bytes` is no use here: all its reads share
    /// one serial queue, so a quiet stderr stalls stdout. The tests catch that.)
    private nonisolated static func drain(
        _ handle: FileHandle, onMessage: @escaping @Sendable (ResticMessage) -> Void
    ) async -> Drained {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "restorey.restic.drain", qos: .utility).async {
                var result = Drained()
                func consume(_ bytes: ArraySlice<UInt8>) {
                    var line = String(decoding: bytes, as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    guard !line.isEmpty else { return }
                    result.tail.append(line)
                    if result.tail.count > tailLength { result.tail.removeFirst() }
                    let message = ResticMessageParser.parse(line)
                    switch message {
                    case .error(let error): result.errors.append(error)
                    case .summary(let summary): result.summary = summary
                    case .exitError(_, let text): result.exitErrorMessage = text
                    default: break
                    }
                    onMessage(message)
                }

                let fd = handle.fileDescriptor
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                var pending: [UInt8] = []
                while true {
                    let count = read(fd, &chunk, chunk.count)
                    if count < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if count == 0 { break }
                    pending.append(contentsOf: chunk[0..<count])
                    var start = 0
                    while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                        consume(pending[start..<newline])
                        start = newline + 1
                    }
                    pending.removeSubrange(0..<start)
                }
                consume(pending[...]) // a last line with no newline
                try? handle.close()
                continuation.resume(returning: result)
            }
        }
    }
}
