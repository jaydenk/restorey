import Foundation
import RestoreyCore

/// The optional "Backing up" and "Backed up" notifications (`NotificationSettings.backupStarted`, `.backupFinished`).
///
/// The runner tells the agent when a backup's restic step starts and when its record is committed. Each call only
/// queues the work and returns, so restic is never held up by the notification centre. A plan's notes are posted
/// one after another, in the order the runner gave them, so a "Backing up" can never land after its backup's end.
/// Every notifier call is bounded by `alertCallTimeout`, as the alerts' are.
///
/// Nothing is posted unless the agent is known to be allowed to post (posting otherwise reports success and shows
/// nothing, docs/spike-findings.md, H3b). A backup that ends in a failure verdict takes the plan's event
/// notification away, so a stale "Backing up" never sits next to the failure; the failure itself is a problem
/// alert (AgentState+Alerts.swift).
extension AgentState {
    /// A backup's restic step is starting: posts "Backing up — <plan>" when Backup started is on.
    public func noteBackupStarted(_ plan: Plan, at date: Date) {
        guard config.notifications.backupStarted else { return }
        let alert = AlertContent.backupStarted(plan: plan, at: date, calendar: eventCalendar, locale: eventLocale)
        enqueueEvent(plan.id) { await self.postEvent(alert, kind: "started", planID: plan.id) }
    }

    /// A backup's record is committed: posts "Backed up — <plan>" when Backup finished is on and the backup saved its
    /// data, and takes the plan's event notification away when it failed.
    public func noteBackupEnded(_ plan: Plan, record: RunRecord) {
        if record.outcome.isFailureVerdict {
            enqueueEvent(plan.id) { await self.removeEvent(planID: plan.id) }
            return
        }
        guard config.notifications.backupFinished,
            let alert = AlertContent.backupFinished(
                plan: plan, record: record, calendar: eventCalendar, locale: eventLocale)
        else { return }
        enqueueEvent(plan.id) { await self.postEvent(alert, kind: "finished", planID: plan.id) }
    }

    /// Waits until every queued started and finished notification has been posted or given up on.
    func eventNotesDelivered() async {
        while let next = eventNotes.values.first { await next.task.value }
    }

    /// Runs `work` after the plan's queued notes.
    private func enqueueEvent(_ planID: UUID, _ work: @escaping @Sendable () async -> Void) {
        guard notifier != nil else { return }
        let previous = eventNotes[planID]?.task
        let token = UUID()
        let task = Task {
            await previous?.value
            await work()
            self.eventNoteFinished(planID, token: token)
        }
        eventNotes[planID] = (token, task)
    }

    private func eventNoteFinished(_ planID: UUID, token: UUID) {
        if eventNotes[planID]?.token == token { eventNotes[planID] = nil }
    }

    private func postEvent(_ alert: AlertContent, kind: String, planID: UUID) async {
        guard let notifier else { return }
        let timeout = alertCallTimeout
        // Its own key: a backup starting while an alert round is asking must still learn the answer.
        await refreshAuthorisation(notifier: notifier, timeout: timeout, key: "authorisation.events")
        guard knownNotificationAuthorisation == true else { return }
        if let failure = await post(alert, notifier: notifier, timeout: timeout) {
            alertLog("Couldn't post the backup \(kind) notification for plan \(planID.uuidString): \(failure)")
        }
    }

    private func removeEvent(planID: UUID) async {
        guard let notifier else { return }
        let identifier = AlertContent.eventIdentifier(for: planID)
        let removed = await guardedCall("remove.\(identifier)", timeout: alertCallTimeout) {
            await notifier.remove(identifiers: [identifier])
        }
        if removed == nil {
            alertLog("Couldn't remove the backup notification for plan \(planID.uuidString): the notification centre didn’t answer within \(alertCallTimeout)")
        }
    }
}
