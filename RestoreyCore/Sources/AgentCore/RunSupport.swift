import Foundation
import RestoreyCore
import Synchronization

/// One in-flight run's interrupt request and the restic process it currently has, so `pause` reaches
/// whichever step (backup, maintenance, init, adopt) is running, or stops the next one starting.
final class RunHandle: Sendable {
    private struct State {
        var intent: InterruptIntent?
        var process: ResticProcess?
    }

    private let state = Mutex(State())

    var intent: InterruptIntent? { state.withLock { $0.intent } }

    /// Records the request and returns the process to interrupt, or nil when there is none or the same
    /// request was already made (a second SIGINT would make restic stop without removing its lock).
    func request(_ intent: InterruptIntent) -> ResticProcess? {
        state.withLock { state in
            guard state.intent != intent else { return nil }
            state.intent = intent
            return state.process
        }
    }

    /// Makes `process` the one to interrupt and returns any request already made, which the caller
    /// passes on before running it (restic then never starts).
    func attach(_ process: ResticProcess) -> InterruptIntent? {
        state.withLock { state in
            state.process = process
            return state.intent
        }
    }

    func detach() {
        state.withLock { $0.process = nil }
    }
}

/// A step's run log. Without a writer (the log couldn't be created) every line counts as dropped, so
/// the record says the log is incomplete instead of silently having none.
final class StepLog: Sendable {
    let writer: RunLogWriter?
    private let missed = Atomic<Int>(0)

    init(writer: RunLogWriter?) {
        self.writer = writer
    }

    func line(_ text: String) {
        if let writer { writer.line(text) } else { missed.add(1, ordering: .relaxed) }
    }

    var droppedLineCount: Int { (writer?.droppedLineCount ?? 0) + missed.load(ordering: .relaxed) }

    func close() { writer?.close() }

    /// The text written for one restic message. Progress lines are left out: they arrive twice a second
    /// and the UI already shows them.
    static func text(for message: ResticMessage) -> String? {
        switch message {
        case .status, .verboseStatus:
            return nil
        case .summary(let s):
            return "Summary: \(s.filesNew) new, \(s.filesChanged) changed and \(s.filesUnmodified) unchanged files, "
                + "\(s.dataAdded) bytes added, snapshot \(s.snapshotID ?? "none (nothing changed)")"
        case .error(let e):
            var text = "Error: \(e.message)"
            if let item = e.item { text += " (\(item))" }
            if let during = e.during { text += " during \(during)" }
            return text
        case .exitError(let code, let message):
            return "Fatal (\(code)): \(message)"
        case .checkSummary(let c):
            return "Check summary: \(c.numErrors) errors"
                + (c.brokenPacks.map { ", broken packs \($0.joined(separator: ", "))" } ?? "")
                + (c.suggestRepairIndex ? ", repair index suggested" : "")
                + (c.suggestPrune ? ", prune suggested" : "")
        case .unknown(let type):
            return "restic message: \(type)"
        case .unparseable(let line):
            return line
        }
    }
}

/// Feeds a running backup's progress to `AgentState.updateRun` in arrival order without blocking
/// restic's drain thread. The "retrying" text (Ruling R14) is the latest stderr line containing
/// "retrying", redacted, and is cleared by the next status line.
final class ProgressFeed: Sendable {
    private let continuation: AsyncStream<ResticMessage>.Continuation
    private let consumer: Task<Void, Never>

    init(state: AgentState, planID: UUID, redactor: Redactor) {
        let (stream, continuation) = AsyncStream<ResticMessage>.makeStream()
        self.continuation = continuation
        consumer = Task {
            var progress: BackupStatus?
            var retrying: String?
            for await message in stream {
                switch message {
                case .status(let status):
                    progress = status
                    retrying = nil
                case .unparseable(let line):
                    retrying = redactor.redact(line)
                default:
                    continue
                }
                await state.updateRun(planID: planID, progress: progress, retrying: retrying)
            }
        }
    }

    /// Cheap and non-blocking: safe on the drain thread.
    func send(_ message: ResticMessage) {
        switch message {
        case .status:
            continuation.yield(message)
        case .unparseable(let line) where line.localizedCaseInsensitiveContains("retrying"):
            continuation.yield(message)
        default:
            break
        }
    }

    /// Waits until every message sent so far has reached the state.
    func finish() async {
        continuation.finish()
        await consumer.value
    }
}

/// The lines restic printed that `collect` matched, for a step that reads restic's stdout (adopt).
final class LineCollector: Sendable {
    private let lines = Mutex<[String]>([])
    private let matches: @Sendable (String) -> Bool

    init(matching: @escaping @Sendable (String) -> Bool) {
        matches = matching
    }

    func collect(_ message: ResticMessage) {
        guard case .unparseable(let line) = message, matches(line) else { return }
        lines.withLock { $0.append(line) }
    }

    var last: String? { lines.withLock { $0.last } }
}
