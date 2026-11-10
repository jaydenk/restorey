import Foundation

/// One ping to a plan's dead-man's-switch check-in URL.
public enum CheckInPing: Sendable, Equatable {
    case start
    case success
    case fail(body: String)
}

/// Sends pings. Implemented in Task 16; failures are the sender's to log, never the run's.
public protocol CheckInSending: Sendable {
    func send(_ ping: CheckInPing, planID: UUID) async
}

/// The pings to send as a run starts.
public func pingsAtStart(trigger: RunTrigger) -> [CheckInPing] {
    [.start]
}

/// The ping to send when a run ends, or nil for none.
///
/// A missing ping is what trips the dead-man's switch, so nil is only for runs that did not really
/// happen or will be retried: `paused`, `cancelled`, `skipped` and `locked` (rescheduled in 15 min).
/// `warning` is a success ping: the data is protected, and the warning reaches the user through the UI.
/// `credentialsUnavailable` is a failure (Task 1 finding): nothing was backed up.
///
/// The fail body is `restic exit code <n>`, or `interrupted` for an interrupted run, then a newline and
/// the last 20 lines of `logTail`, redacted. Restic exit codes for outcomes that do not carry one:
/// wrong password 12, repository missing 10, credentials unavailable 1.
public func pingAtEnd(outcome: RunOutcome, logTail: [String], redactor: Redactor) -> CheckInPing? {
    let heading: String
    switch outcome {
    case .success, .unchanged, .warning:
        return .success
    case .paused, .cancelled, .skipped, .locked:
        return nil
    case .failed(let exitCode, _): heading = "restic exit code \(exitCode)"
    case .wrongPassword: heading = "restic exit code 12"
    case .repositoryMissing: heading = "restic exit code 10"
    case .credentialsUnavailable: heading = "restic exit code 1"
    case .interrupted: heading = "interrupted"
    }
    let tail = logTail.suffix(20).map { redactor.redact($0) }
    return .fail(body: heading + "\n" + tail.joined(separator: "\n"))
}
