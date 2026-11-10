import Foundation
import RestoreyCore

/// The runner's decisions that depend only on their inputs: what maintenance is due, what a record does
/// to a plan's history and alerts, and the reasons shown to the user.
extension PlanRunner {
    /// The maintenance due after a backup that ended `outcome` (spec §5.6, §6.1). Nothing follows a
    /// backup that didn't finish. `forget` follows one that made a snapshot (`.afterEachBackup`) or any
    /// successful one a day after the last forget (`.daily`); `prune` (if enabled) a week after the last
    /// prune, or the plan's creation; a plain `unlock` then `check` a week after the last check. A clock
    /// that went backwards makes a step due rather than leaving it waiting.
    static func maintenance(plan: Plan, history: PlanRunHistory, after outcome: RunOutcome, now: Date) -> [ResticOperation] {
        let madeSnapshot: Bool
        switch outcome {
        case .success(let snapshotID): madeSnapshot = snapshotID != nil
        case .warning: madeSnapshot = true
        case .unchanged: madeSnapshot = false
        default: return []
        }
        func due(since last: Date?, every interval: TimeInterval) -> Bool {
            guard let last else { return true }
            return now < last || now.timeIntervalSince(last) >= interval
        }
        var steps: [ResticOperation] = []
        switch plan.forgetCadence {
        case .afterEachBackup: if madeSnapshot { steps.append(.forget(dryRun: false)) }
        case .daily: if due(since: history.lastForgetAt, every: day) { steps.append(.forget(dryRun: false)) }
        }
        if plan.pruneEnabled, due(since: history.lastPruneAt ?? plan.createdAt, every: week) { steps.append(.prune) }
        if due(since: history.lastCheckAt, every: week) { steps += [.unlock, .check] }
        return steps
    }

    /// The history fields one record moves.
    static func apply(_ record: RunRecord, stoppedReason: String?, to history: inout PlanRunHistory) {
        let ended = record.endedAt
        switch record.operation {
        case .backup:
            noteAttempt(at: record.startedAt, in: &history)
            switch record.outcome {
            case .success(let snapshotID):
                history.lastSuccessAt = ended
                if snapshotID != nil { history.lastSnapshotAt = ended }
                history.stoppedReason = nil
            case .unchanged:
                history.lastSuccessAt = ended
                history.stoppedReason = nil
            case .warning:
                history.lastSuccessAt = ended
                history.lastSnapshotAt = ended
                history.stoppedReason = nil
            case .wrongPassword, .repositoryMissing, .credentialsUnavailable:
                history.stoppedReason = stoppedReason
            default:
                break
            }
        case .forget(dryRun: false):
            if case .success = record.outcome { history.lastForgetAt = ended }
        case .prune:
            if case .success = record.outcome { history.lastPruneAt = ended }
        case .check:
            switch record.outcome {
            case .paused, .cancelled, .locked, .skipped: break // no verdict: check again next time
            default: history.lastCheckAt = ended
            }
        default:
            break
        }
    }

    /// Every backup attempt moves `lastAttemptAt`, and clears a pause that has run out: an expired
    /// `pausedUntil` would otherwise make the plan due on every tick.
    static func noteAttempt(at date: Date, in history: inout PlanRunHistory) {
        history.lastAttemptAt = date
        if let until = history.pausedUntil, until <= date { history.pausedUntil = nil }
    }

    /// Raises (with fresh notification state) or clears the conditions history decides. The probe-driven
    /// ones (`fullDiskAccessMissing`, `notificationsOff`) are left alone.
    static func refreshAlerts(_ history: inout PlanRunHistory, plan: Plan, now: Date) {
        let raised = activeConditions(history: history, plan: plan, now: now)
        for condition in [AlertCondition.backupFailed, .checkFailed, .configurationError, .noRecentSuccess] {
            if raised.contains(condition) {
                if history.activeAlerts[condition] == nil {
                    history.activeAlerts[condition] = AlertNotificationState(raisedAt: now, lastNotifiedAt: nil, count: 0)
                }
            } else {
                history.activeAlerts[condition] = nil
            }
        }
    }

    /// Why a plan can't back up at all, before any condition is checked.
    static func refusal(_ plan: Plan) -> AgentError? {
        let errors = plan.validationErrors()
        if !errors.isEmpty { return .invalidPlan(errors) }
        if plan.recoveryKitConfirmedAt == nil { return .recoveryKitNotConfirmed(name: plan.name) }
        return nil
    }

    static func stoppedReason(for outcome: RunOutcome, helperFailure: String?) -> String? {
        let base: String
        switch outcome {
        case .wrongPassword: base = "The repository password is wrong"
        case .repositoryMissing: base = "There's no restic repository at this plan's address"
        case .credentialsUnavailable: base = keychainUnreadable
        default: return nil
        }
        return joined(base, helperFailure)
    }

    /// A sentence for an outcome, for logs and the app's error messages.
    static func explain(_ outcome: RunOutcome, stoppedReason: String?) -> String {
        if let stoppedReason { return stoppedReason }
        switch outcome {
        case .success(let snapshotID): return snapshotID.map { "Succeeded, snapshot \($0)" } ?? "Succeeded"
        case .unchanged: return "Nothing changed, so restic made no snapshot"
        case .warning(let unreadable): return "Finished, but \(unreadable) files couldn't be read"
        case .paused: return "Paused"
        case .cancelled: return "Cancelled"
        case .locked: return "Another restic holds the repository's lock"
        case .interrupted: return "Interrupted"
        case .skipped(let reason): return "Skipped (\(reason))"
        case .failed(_, let reason): return reason
        case .repositoryMissing, .wrongPassword, .credentialsUnavailable:
            return Self.stoppedReason(for: outcome, helperFailure: nil) ?? "Failed"
        }
    }

    static func joined(_ text: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return text }
        var head = text
        while head.hasSuffix(".") { head.removeLast() }
        return "\(head). \(detail)"
    }
}
