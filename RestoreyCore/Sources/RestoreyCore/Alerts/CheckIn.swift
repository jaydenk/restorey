import Foundation

/// One ping to a plan's dead-man's-switch check-in URL.
///
/// There is no start ping (Ruling R57): Healthchecks.io marks a check that got a start signal and no
/// success within its grace time as down, and a paused, cancelled or lock-retried run has no honest
/// ending to send, so a start would raise a false alarm. The check alerts only when no success arrives
/// within its period and grace.
public enum CheckInPing: Sendable, Equatable {
    case success
    case fail(body: String)
}

/// Sends pings. Implemented in Task 16; failures are the sender's to log, never the run's.
public protocol CheckInSending: Sendable {
    func send(_ ping: CheckInPing, planID: UUID) async
}

/// The ping to send when a run ends, or nil for none.
///
/// A missing ping is what trips the dead-man's switch, so nil is only for runs that did not really
/// happen or will be retried: `paused`, `cancelled`, `skipped`, `locked` (rescheduled in 15 min) and
/// `stoppedBySystem` (the Mac logging out or shutting down; retried in 15 min, Ruling R67).
/// `warning` is a success ping: the data is protected, and the warning reaches the user through the UI.
/// `credentialsUnavailable` is a failure (Task 1 finding): nothing was backed up.
///
/// The fail body is `restic exit code <n>`, `not started` for a failure found before restic ran (a missing
/// source, Full Disk Access missing; exit code `RunOutcome.notStartedExitCode`), or `interrupted` for an
/// interrupted run, then a newline and
/// the last 20 lines of `logTail`, redacted. Restic exit codes for outcomes that do not carry one:
/// wrong password 12, repository missing 10, credentials unavailable 1.
public func pingAtEnd(outcome: RunOutcome, logTail: [String], redactor: Redactor) -> CheckInPing? {
    let heading: String
    switch outcome {
    case .success, .unchanged, .warning:
        return .success
    case .paused, .cancelled, .skipped, .locked, .stoppedBySystem:
        return nil
    case .failed(let exitCode, _) where exitCode == RunOutcome.notStartedExitCode: heading = "not started"
    case .failed(let exitCode, _): heading = "restic exit code \(exitCode)"
    case .wrongPassword: heading = "restic exit code 12"
    case .repositoryMissing: heading = "restic exit code 10"
    case .credentialsUnavailable: heading = "restic exit code 1"
    case .interrupted: heading = "interrupted"
    }
    // Redact the whole tail before cutting it, so a secret that spans lines (a PEM key, JSON) matches.
    let redacted = redactor.redact(logTail.joined(separator: "\n"))
    let tail = redacted.split(separator: "\n", omittingEmptySubsequences: false).suffix(20)
    return .fail(body: heading + "\n" + tail.joined(separator: "\n"))
}
