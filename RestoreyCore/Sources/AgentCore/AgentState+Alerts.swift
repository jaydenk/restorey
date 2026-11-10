import Foundation
import RestoreyCore

/// Alert delivery: on every status change and every scheduler tick, each plan's conditions are worked
/// out (`alertConditions`), raised or cleared in its `activeAlerts` (`reconcileAlerts`), the ones due
/// are posted through the notifier, and the notification state is saved in `state.json`.
///
/// Nothing is posted while the agent isn't authorised: posting then reports success and shows nothing
/// (docs/spike-findings.md, H3b). `notificationsOff` is raised instead, for the app to show, and the
/// alerts due wait uncounted, so they go out on the first round after the user allows notifications.
/// A post the system refuses isn't counted either, and is tried again on the next round.
///
/// Deliveries never overlap. One asked for while another runs follows it, with fresh state.
extension AgentState {
    /// Called once at startup. Delivers at once, so alerts raised before the agent last stopped, and
    /// `notificationsOff`, are brought up to date.
    /// - Parameter log: lines for the agent's log, which name the plan and condition, never a secret.
    public func attach(notifier: any AlertNotifying, log: @escaping @Sendable (String) -> Void) {
        self.notifier = notifier
        alertLog = log
        scheduleAlertDelivery()
    }

    /// Delivers the alerts now and returns once done. The scheduler's tick calls this.
    public func deliverAlerts() async {
        scheduleAlertDelivery()
        await alertsDelivered()
    }

    /// Waits for the delivery in progress, and any asked for during it.
    func alertsDelivered() async {
        while let delivery = alertDelivery { await delivery.value }
    }

    /// Starts a delivery, or asks the one in progress to run again when it ends.
    func scheduleAlertDelivery() {
        guard notifier != nil, loadError == nil else { return }
        guard alertDelivery == nil else {
            alertDeliveryAgain = true
            return
        }
        alertDelivery = Task {
            repeat {
                alertDeliveryAgain = false
                await deliverOnce()
            } while alertDeliveryAgain
            alertDelivery = nil
        }
    }

    private func deliverOnce() async {
        guard let notifier else { return }
        let authorised = await notifier.authorisationStatus()
        do {
            // Through the write gate, so no run's record can land between reading the alerts and saving them.
            try await serialisedWrite {
                let now = now()
                var state = runState
                var changed = false
                for plan in config.plans {
                    let history = state.plans[plan.id] ?? PlanRunHistory()
                    let active = alertConditions(
                        history: history, plan: plan, now: now, fullDiskAccessMissing: fdaMissing,
                        notificationsAuthorised: authorised)
                    var (next, toNotify) = reconcileAlerts(previous: history.activeAlerts, active: active, now: now)
                    if authorised == true {
                        for condition in toNotify {
                            guard let alert = AlertContent(condition: condition, plan: plan, history: history, now: now)
                            else { continue }
                            do {
                                try await notifier.post(alert)
                                next[condition]?.markNotified(at: now)
                                alertLog("Posted the \(condition.rawValue) notification for plan \(plan.id.uuidString)")
                            } catch {
                                alertLog(
                                    "Couldn't post the \(condition.rawValue) notification for plan \(plan.id.uuidString); trying again at the next check: \(error)")
                            }
                        }
                    }
                    if next != history.activeAlerts {
                        state.plans[plan.id, default: PlanRunHistory()].activeAlerts = next
                        changed = true
                    }
                }
                guard changed else { return }
                try await saveState(state)
                pushStatus(deliveringAlerts: false)
            }
        } catch {
            // The notifications went out, but their state wasn't saved: the next round may repeat one.
            let message = (error as? AgentError)?.message ?? "\(error)"
            alertLog("Couldn't save the alert state: \(message)")
        }
    }
}
