import Foundation
import RestoreyCore

/// Alert delivery: on every status change and every scheduler tick, each plan's conditions are worked
/// out (`alertConditions`), raised or cleared in its `activeAlerts` (`reconcileAlerts`), the ones due
/// are posted through the notifier, and the notification state is saved in `state.json`.
///
/// A round has three steps, so the notification centre can never hold up a run or a save (Ruling R44):
/// 1. under the write gate, raise and clear, and work out what to post;
/// 2. outside the gate, ask for authorisation and post, each call bounded by `alertCallTimeout` (10 s);
/// 3. under the gate again, mark what was actually delivered, if its alert is still the one raised.
/// A post that times out counts as not delivered. An authorisation call that times out keeps the last
/// answer the notifier gave; with none yet, nothing is posted and `notificationsOff` is left as it was.
/// While a call is still suspended past its timeout, no second call with the same key is made: it is
/// treated as unanswered at once, so a hung `usernoted` can't pile up calls (Ruling R48). A call held for
/// more than 10 minutes is abandoned and a fresh one made, so one that never returns can't freeze its
/// key for good; an abandoned authorisation call raises `notificationsOff` until an answer comes, so the
/// menu bar warns that notifications aren't working (Ruling R49). Nobody waits for a round except
/// `deliverAlerts`, and it waits a bounded time.
///
/// Nothing is posted while the agent isn't authorised: posting then reports success and shows nothing
/// (docs/spike-findings.md, H3b). `notificationsOff` is raised instead, for the app to show, and the
/// alerts due wait uncounted, so they go out on the first round after the user allows notifications.
/// A post the system refuses isn't counted either, and is tried again on the next round. A banner
/// several plans share (Full Disk Access) is posted once per round.
///
/// In the load-error state no plan's alerts are delivered. One agent-wide notification says the settings
/// can't be read, on the same back-off, with its state kept in memory (Ruling R45).
///
/// Deliveries never overlap. One asked for while another runs follows it, with fresh state.
extension AgentState {
    /// Called once at startup. Delivers at once, so alerts raised before the agent last stopped, and
    /// `notificationsOff`, are brought up to date.
    /// - Parameters:
    ///   - log: lines for the agent's log, which name the plan and condition, never a secret.
    ///   - callTimeout: how long each notifier call may take; injectable for tests.
    public func attach(
        notifier: any AlertNotifying, log: @escaping @Sendable (String) -> Void, callTimeout: Duration = .seconds(10)
    ) {
        self.notifier = notifier
        alertLog = log
        alertCallTimeout = callTimeout
        scheduleAlertDelivery()
    }

    /// Delivers the alerts now and waits for at most `budget`. False if the round was still running.
    @discardableResult
    public func deliverAlerts(waitingAtMost budget: Duration = .seconds(60)) async -> Bool {
        scheduleAlertDelivery()
        return await Self.bounded(budget) { await self.alertsDelivered() } != nil
    }

    /// Waits for the delivery in progress, and any asked for during it.
    func alertsDelivered() async {
        while let delivery = alertDelivery { await delivery.value }
    }

    /// How long a suspended notifier call holds its key before it is abandoned.
    static let notifierCallAbandonment: TimeInterval = 600

    /// Starts a delivery, or asks the one in progress to run again when it ends. Never waits.
    func scheduleAlertDelivery() {
        guard notifier != nil else { return }
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

    // MARK: Check-in results

    /// What the check-in service said to a plan's ping: a 4xx raises `checkInRejected`, a 2xx clears
    /// it, anything else changes nothing.
    public func checkInResult(planID: UUID, status: Int) async {
        let rejected: Bool
        switch status {
        case 400..<500: rejected = true
        case 200..<300: rejected = false
        default: return
        }
        checkInRejectedStatus[planID] = rejected ? status : nil
        let raised = runState.plans[planID]?.activeAlerts[.checkInRejected] != nil
        guard rejected != raised else { return }
        let now = now()
        do {
            try await updateHistory(planID) { history in
                if !rejected {
                    history.activeAlerts[.checkInRejected] = nil
                } else if history.activeAlerts[.checkInRejected] == nil {
                    history.activeAlerts[.checkInRejected] = AlertNotificationState(
                        raisedAt: now, lastNotifiedAt: nil, count: 0)
                }
            }
        } catch {
            // A plan deleted since the ping went out, or the load-error state.
            alertLog("Couldn't record the check-in result for plan \(planID.uuidString): \(Self.describe(error))")
        }
    }

    // MARK: A round

    /// One notification to post, and the alert it is for.
    private struct Pending: Sendable {
        var planID: UUID
        var condition: AlertCondition
        var raisedAt: Date
        var alert: AlertContent
    }

    private func deliverOnce() async {
        guard let notifier else { return }
        let timeout = alertCallTimeout
        // An answer that arrives after its timeout is still recorded, for the next round.
        _ = await guardedCall("authorisation", timeout: timeout) {
            let answer = await notifier.authorisationStatus()
            await self.noteAuthorisation(answer)
            return answer
        }
        // `.none`: the notifier has never answered. Nothing is posted, and `notificationsOff` is neither
        // raised nor cleared. An abandoned call with no answer since counts as not authorised.
        let abandoned = authorisationAbandoned
        let known: Bool?? = abandoned ? .some(false) : lastAuthorisation
        let authorised: Bool? = known ?? nil
        if let loadError {
            await deliverLoadError(loadError, authorised: authorised, notifier: notifier)
            return
        }

        // 1. Raise and clear, and work out what is due.
        let now = now()
        var pending: [Pending] = []
        await underGate("the alert state") {
            var state = runState
            var changed = false
            for plan in config.plans {
                let history = state.plans[plan.id] ?? PlanRunHistory()
                var active = alertConditions(
                    history: history, plan: plan, now: now, fullDiskAccessMissing: fdaMissing,
                    notificationsAuthorised: known == nil ? true : authorised)
                if known == nil, history.activeAlerts[.notificationsOff] != nil { active.insert(.notificationsOff) }
                let (next, toNotify) = reconcileAlerts(previous: history.activeAlerts, active: active, now: now)
                if authorised == true {
                    for condition in toNotify {
                        guard let raisedAt = next[condition]?.raisedAt,
                            let alert = AlertContent(
                                condition: condition, plan: plan, history: history, now: now,
                                checkInStatus: checkInRejectedStatus[plan.id])
                        else { continue }
                        pending.append(Pending(planID: plan.id, condition: condition, raisedAt: raisedAt, alert: alert))
                    }
                }
                if next != history.activeAlerts {
                    state.plans[plan.id, default: PlanRunHistory()].activeAlerts = next
                    changed = true
                }
            }
            guard changed else { return }
            defer { pushStatus(deliveringAlerts: false) }
            try await saveStateKeepingInMemory(state)
        }
        guard !pending.isEmpty else { return }

        // 2. Post, outside the gate. A banner several plans share goes out once.
        var delivered: Set<String> = []
        var tried: Set<String> = []
        for item in pending where tried.insert(item.alert.identifier).inserted {
            if let failure = await post(item.alert, notifier: notifier, timeout: timeout) {
                alertLog(
                    "Couldn't post the \(item.condition.rawValue) notification for plan \(item.planID.uuidString); trying again at the next check: \(failure)")
            } else {
                delivered.insert(item.alert.identifier)
                alertLog("Posted the \(item.condition.rawValue) notification for plan \(item.planID.uuidString)")
            }
        }
        guard !delivered.isEmpty else { return }

        // 3. Mark what went out, unless its alert has cleared (or cleared and been raised again) meanwhile.
        await underGate("which notifications were posted") {
            var state = runState
            var changed = false
            for item in pending where delivered.contains(item.alert.identifier) {
                guard state.plans[item.planID]?.activeAlerts[item.condition]?.raisedAt == item.raisedAt else { continue }
                state.plans[item.planID]?.activeAlerts[item.condition]?.markNotified(at: now)
                changed = true
            }
            guard changed else { return }
            defer { pushStatus(deliveringAlerts: false) }
            try await saveStateKeepingInMemory(state)
        }
    }

    private func deliverLoadError(_ message: String, authorised: Bool?, notifier: any AlertNotifying) async {
        let now = now()
        var state = loadErrorAlert ?? AlertNotificationState(raisedAt: now, lastNotifiedAt: nil, count: 0)
        loadErrorAlert = state
        guard authorised == true, shouldNotify(state, now: now) else { return }
        if let failure = await post(.loadError(message), notifier: notifier, timeout: alertCallTimeout) {
            alertLog("Couldn't post the notification that the settings can't be read: \(failure)")
            return
        }
        alertLog("Posted the notification that the settings can't be read")
        state.markNotified(at: now)
        loadErrorAlert = state
    }

    /// Nil when posted, otherwise why not.
    private func post(_ alert: AlertContent, notifier: any AlertNotifying, timeout: Duration) async -> String? {
        let outcome = await guardedCall("post.\(alert.identifier)", timeout: timeout) { () -> String? in
            do {
                try await notifier.post(alert)
                return nil
            } catch {
                return "\(error)"
            }
        }
        return outcome ?? "the notification centre didn't answer within \(timeout)"
    }

    /// `work`'s result within `timeout`, or nil. Nil at once, without calling, while the last call with
    /// this key is still suspended.
    /// A call still held after `notifierCallAbandonment` is abandoned (logged once) and a fresh call made.
    func guardedCall<T: Sendable>(
        _ key: String, timeout: Duration, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let now = now()
        if let held = outstandingNotifierCalls[key] {
            guard now.timeIntervalSince(held.since) > Self.notifierCallAbandonment else { return nil }
            alertLog("notifier call \(key) abandoned after 10 minutes")
            if key == "authorisation" { authorisationAbandoned = true }
        }
        let token = UUID()
        outstandingNotifierCalls[key] = (token, now)
        return await Self.bounded(timeout) {
            let value = await work()
            await self.notifierCallReturned(key, token: token)
            return value
        }
    }

    /// The notification authorisation as the alert rounds last learnt it, for `hello` (Ruling R68): nil
    /// until the notifier has answered once (or when it said "not asked yet"), false while an abandoned
    /// call has had no answer since. Never asks the notification centre, so `hello` can't wait on it.
    public var knownNotificationAuthorisation: Bool? {
        if authorisationAbandoned { return false }
        return lastAuthorisation ?? nil
    }

    /// The heartbeat's reply, built from what the agent already holds: nothing here waits on another
    /// process (Ruling R68), so a notification centre that has stopped answering can't make the app
    /// think the agent is dead.
    public func helloReply(
        agentVersion: String, agentBuild: String, executablePath: String, executableFingerprint: String?
    ) -> HelloReply {
        HelloReply(
            agentVersion: agentVersion, agentBuild: agentBuild, executablePath: executablePath,
            draining: isDraining, notificationsAuthorised: knownNotificationAuthorisation,
            executableFingerprint: executableFingerprint)
    }

    private func noteAuthorisation(_ answer: Bool?) {
        lastAuthorisation = .some(answer)
        authorisationAbandoned = false
    }

    /// The token of the call holding `key`, if one is.
    func notifierCallToken(_ key: String) -> UUID? {
        outstandingNotifierCalls[key]?.token
    }

    /// Releases `key` only if it is still this call's: an abandoned call returning late leaves the
    /// newer call's entry alone.
    func notifierCallReturned(_ key: String, token: UUID) {
        if outstandingNotifierCalls[key]?.token == token { outstandingNotifierCalls[key] = nil }
    }

    /// Runs `body` under the write gate, logging a failure instead of throwing it.
    private func underGate(_ what: String, _ body: () async throws -> Void) async {
        do {
            try await serialisedWrite(body)
        } catch {
            // Kept in memory (`saveStateKeepingInMemory`), so the next round doesn't post it again.
            alertLog("Couldn't save \(what): \(Self.describe(error))")
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? AgentError)?.message ?? "\(error)"
    }
}
