import Foundation

/// How a restic process ended. Feed the fields to `classify`.
public struct ResticTermination: Sendable, Equatable {
    /// restic's exit status. When the process was ended by a signal this is `128 + signal`, the shell
    /// convention, and `terminatedBySignal` says which.
    public var exitCode: Int32
    /// Set when the process died from a signal rather than exiting, for example SIGKILL after an
    /// interrupt that restic did not honour in time.
    public var terminatedBySignal: Int32?
    /// True when `ResticProcess` itself sent the SIGKILL, because restic ignored our SIGINT for the
    /// whole grace period. Only that kind of signal death counts as the pause or cancel we asked for.
    public var killedByUs: Bool
    /// True when an interrupt arrived before the process was spawned, so restic never ran. Then
    /// `exitCode` is 130, `pid` is 0 and `interruptIntent` is the intent that was given.
    public var neverStarted: Bool
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
        exitCode: Int32, terminatedBySignal: Int32? = nil, killedByUs: Bool = false,
        neverStarted: Bool = false, interruptIntent: InterruptIntent? = nil,
        exitErrorMessage: String? = nil, stderrTail: [String] = [], messages: [ResticItemError] = [],
        summary: BackupSummary? = nil, pid: pid_t
    ) {
        self.exitCode = exitCode
        self.terminatedBySignal = terminatedBySignal
        self.killedByUs = killedByUs
        self.neverStarted = neverStarted
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
/// - Cancelling the task that awaits `run` means `interrupt(.cancel)`: `run` still waits for the real
///   exit and returns a termination with `interruptIntent == .cancel`.
/// - `onMessage` is called from the two reader tasks, in order within a stream but with no ordering
///   between the streams, and may be called concurrently. It runs synchronously on a drain thread, so
///   it must be cheap and must never block: a slow callback stalls that stream, and restic with it.
public actor ResticProcess {
    private let executable: URL
    private let invocation: ResticInvocation
    private let planID: UUID
    private let supervisor: SupervisedProcesses
    private let homeDirectory: URL

    private var process: Process?
    private var started = false
    private var exited = false
    private var killed = false
    private var intent: InterruptIntent?

    /// - Parameters:
    ///   - planID: the plan this run belongs to, recorded in `supervisor` from spawn until restic exits.
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

    /// Runs restic to completion. `onMessage` runs synchronously on a drain thread (one per stream);
    /// keep it cheap and never block in it.
    public func run(onMessage: @escaping @Sendable (ResticMessage) -> Void) async throws -> ResticTermination {
        try await withTaskCancellationHandler {
            try await runToCompletion(onMessage: onMessage)
        } onCancel: {
            Task { await self.interrupt(.cancel) }
        }
    }

    private struct ExitInfo: Sendable {
        var signalled: Bool
        var status: Int32
    }

    private func runToCompletion(onMessage: @escaping @Sendable (ResticMessage) -> Void) async throws -> ResticTermination {
        guard !started else { throw ResticProcessError.alreadyStarted }
        started = true

        // An interrupt that arrived first wins: restic is not started at all.
        if let pending = intent {
            return ResticTermination(exitCode: 130, neverStarted: true, interruptIntent: pending, pid: 0)
        }

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

        // Set before `run()`, so an immediate exit is still seen. The handler reads the status itself:
        // `terminationReason` must not be read before the process has terminated.
        let (exitEvents, exitSignal) = AsyncStream<ExitInfo>.makeStream()
        process.terminationHandler = { finished in
            exitSignal.yield(ExitInfo(signalled: finished.terminationReason == .uncaughtSignal,
                                      status: finished.terminationStatus))
            exitSignal.finish()
        }

        try process.run()
        // The parent's copies of the write ends must close or the readers never see end of file.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let pid = process.processIdentifier
        self.process = process
        // Bind the pid to its start time, and only once the kernel confirms it is still our own child:
        // if restic has already exited and been reaped, the pid may already be someone else's, so it is
        // not recorded at all (a helper call from it is then refused, never granted).
        var supervisedSince: KernelProcessInfo.StartTime?
        if let info = processInfo(pid: pid), info.parentPID == getpid() {
            await supervisor.insert(pid: pid, planID: planID, startTime: info.startTime)
            supervisedSince = info.startTime
        }

        async let out = Self.drain(stdout.fileHandleForReading, onMessage: onMessage)
        async let err = Self.drain(stderr.fileHandleForReading, onMessage: onMessage)
        // Wait in an unstructured task, which cancellation of this task does not reach, so we always
        // wait for the real exit.
        let exit = await Task {
            var info: ExitInfo?
            for await value in exitEvents { info = value }
            return info
        }.value
        // restic has been reaped, so its pid is free for reuse: stop trusting it now, not after the
        // drains, which a grandchild holding stdout or stderr open can keep going much longer.
        if let supervisedSince { await supervisor.remove(pid: pid, startTime: supervisedSince) }
        let stdoutResult = await out
        let stderrResult = await err

        exited = true

        let signalled = exit?.signalled ?? false
        let status = exit?.status ?? -1
        return ResticTermination(
            exitCode: signalled ? 128 + status : status,
            terminatedBySignal: signalled ? status : nil,
            killedByUs: killed && signalled && status == SIGKILL,
            interruptIntent: intent,
            exitErrorMessage: stderrResult.exitErrorMessage ?? stdoutResult.exitErrorMessage,
            stderrTail: stderrResult.tail,
            messages: stderrResult.errors + stdoutResult.errors,
            summary: stdoutResult.summary ?? stderrResult.summary,
            pid: pid
        )
    }

    /// Asks restic to stop with SIGINT, and kills it with SIGKILL if it is still running after
    /// `killAfter`. Returns at once; the kill is sent later from a background task. The last intent
    /// given is reported. Before the process is spawned the intent is kept, and `run` then does not
    /// start restic (`neverStarted`). After exit it does nothing.
    public func interrupt(_ intent: InterruptIntent, killAfter: Duration = .seconds(10)) {
        guard !exited else { return }
        self.intent = intent
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
        killIfStillRunning(after: killAfter)
    }

    /// Sends SIGKILL after `delay` if restic is still running, without another SIGINT (a second one
    /// makes restic stop without removing its lock). Each call arms its own timer, so a later, shorter
    /// deadline wins: the system stop uses it to bring forward a pause's SIGKILL (Ruling R67).
    public func killIfStillRunning(after delay: Duration) {
        Task { [weak self] in
            // An explicit tolerance: with none, the system is free to fire the timer late to coalesce
            // wake-ups, and a 10 s grace was measured ending 0.45–0.56 s late while other processes ran,
            // so SIGKILL came noticeably after the grace period.
            try? await Task.sleep(for: delay, tolerance: Self.killTimerTolerance)
            await self?.killIfStillRunning()
        }
    }

    /// How late the SIGKILL after an interrupt's grace period may come.
    static let killTimerTolerance: Duration = .milliseconds(50)

    private func killIfStillRunning() {
        guard let process, !exited, process.isRunning else { return }
        killed = true
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
