import Foundation
import RestoreyCore

/// Building `AgentStatus` and pushing it to the app.
extension AgentState {
    // MARK: Status

    /// Called with the new status after every phase change, and for progress at most every
    /// `progressPushInterval`. The agent forwards it to connected apps.
    public func setStatusObserver(_ observer: (@Sendable (AgentStatus) -> Void)?) {
        self.observer = observer
    }

    public func status() -> AgentStatus {
        let now = now()
        statusSequence += 1
        if let loadError {
            // Without history nothing can be scheduled, but the user still sees their plans.
            let plans = onlyStateUnreadable
                ? config.plans.map {
                    PlanStatus(plan: $0, phase: .stopped(reason: loadError), lastRecord: nil, nextRunAt: nil,
                               alerts: [.configurationError])
                }
                : []
            return AgentStatus(
                plans: plans, configError: loadError, fdaMissing: nil, generatedAt: now,
                agentRun: statusRun, sequence: statusSequence, network: onlyStateUnreadable ? config.network : nil,
                notifications: onlyStateUnreadable ? config.notifications : nil)
        }
        return AgentStatus(
            plans: config.plans.map { planStatus($0, now: now) }, configError: nil, fdaMissing: fdaMissing,
            generatedAt: now, agentRun: statusRun, sequence: statusSequence, network: config.network,
            notifications: config.notifications, uploadSpeed: uploadSpeedStatus)
    }

    /// The upload speed where the Mac is, and whether any test is running.
    private var uploadSpeedStatus: UploadSpeedStatus? {
        uploadSpeedView.map { UploadSpeedStatus(network: $0.network, record: $0.record, testing: speedTestsRunning > 0) }
    }

    /// A test has started on `key`'s network (the daily one, one before a backup, or Test now): pushes the status with
    /// `testing` set. Until the runner next looks, the measurement shown is the one last seen for that network.
    func speedTestBegan(on key: NetworkKey) {
        speedTestsRunning += 1
        if uploadSpeedView?.network != key { uploadSpeedView = UploadSpeedStatus(network: key, record: nil, testing: false) }
        pushStatus(deliveringAlerts: false)
    }

    /// The runner's view of the network the Mac is on and its measurement (nil with no network). Pushes the status when
    /// that or `testing` changed; `endingTest` counts a test that has ended, so its end is pushed with the result.
    @discardableResult
    func noteUploadSpeed(network: NetworkKey?, record: UploadSpeedRecord?, endingTest: Bool = false) -> AgentStatus {
        let before = uploadSpeedStatus
        if endingTest { speedTestsRunning = max(0, speedTestsRunning - 1) }
        uploadSpeedView = UploadSpeedStatus(network: network, record: record, testing: false)
        guard uploadSpeedStatus != before else { return status() }
        return pushStatus(deliveringAlerts: false)
    }

    /// The Mac-wide network rules the preflight applies (Ruling P2-6).
    var networkSettings: NetworkSettings { config.network }

    /// The sentence for a tidy that was held back, while it is the plan's newest `forget` (the next one that runs, or
    /// is held back again, replaces it).
    private static func tidyHeldBack(_ history: PlanRunHistory) -> String? {
        guard let newest = history.recent.first(where: { $0.operation == .forget(dryRun: false) }),
            case .skipped(let reason) = newest.outcome, newest.isForgetHeldBack
        else { return nil }
        return reason.summary
    }

    private func planStatus(_ plan: Plan, now: Date) -> PlanStatus {
        let history = runState.plans[plan.id] ?? PlanRunHistory()
        let phase: PlanPhase
        if let run = running[plan.id] {
            phase = .running(run.progress, retrying: run.retrying)
        } else if let reason = history.stopReason(for: plan) {
            phase = .stopped(reason: reason)
        } else if let until = history.pausedUntil, until > now {
            phase = .paused(until: min(until, now.addingTimeInterval(PauseLength.longest.seconds)))
        } else if case .skipped(let reason)? = history.recent.first(where: { !$0.isForgetHeldBack })?.outcome {
            // A tidy held back for a jump in unreadable files is a note on the tidy, not a skipped backup.
            phase = .skipped(reason)
        } else {
            phase = .idle
        }
        let next = nextRunDate(plan: plan, history: history, now: now)
        var raised = activeConditions(history: history, plan: plan, now: now).union(history.activeAlerts.keys)
        // A probe since the run that raised it found access granted: the alert is gone now, not after the
        // next delivery round clears it from `activeAlerts` (or never, with no notifier attached).
        if !fullDiskAccessAlertStands(history: history, fullDiskAccessMissing: fdaMissing) {
            raised.remove(.fullDiskAccessMissing)
        }
        let alerts = raised.sorted { $0.rawValue < $1.rawValue }
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: history.recent.first,
            nextRunAt: next == .distantFuture ? nil : next, alerts: alerts,
            lastBackup: history.lastBackupRecord, repositorySize: history.repositorySize,
            setupState: PlanSetupState(plan: plan),
            latestBackupRecord: history.recent.first { $0.operation == .backup },
            latestBackupVerdict: history.recent.first { $0.operation == .backup && $0.outcome.isVerdict },
            earlierRemovalProblem: history.pendingEarlierRemoval == nil
                ? nil : history.pendingEarlierRemovalFailures?.noticeReason,
            tidyHeldBack: Self.tidyHeldBack(history))
    }

    /// Pushes the status and, unless `deliveringAlerts` is false, has the alerts delivered for it: every
    /// status change can raise or clear one. Progress pushes and the delivery's own push pass false.
    @discardableResult
    func pushStatus(deliveringAlerts: Bool = true) -> AgentStatus {
        let status = status()
        lastPushed = Self.pushed(status)
        observer?(status)
        if deliveringAlerts { scheduleAlertDelivery() }
        return status
    }

    /// Pushes the status if a plan's phase, alerts or being due has changed since the last push with
    /// nothing having called for one: a pause running out, a plan falling due, an overdue alert. The
    /// scheduler calls this on every tick.
    public func pushStatusIfChanged() {
        guard Self.pushed(status()) != lastPushed else { return }
        pushStatus()
    }

    private static func pushed(_ status: AgentStatus) -> [UUID: PushedPlan] {
        Dictionary(status.plans.map { ($0.plan.id, PushedPlan($0, now: status.generatedAt)) }) { first, _ in first }
    }

    /// A pause can only be `PauseLength.longest` (a day). One that ends later than that from now was set before
    /// the clock went backwards, and would last as long again as the clock moved: it is cut back to
    /// a day from now and saved, so it then runs out normally (final review M2). The scheduler's
    /// tick calls this. A save that fails is tried again at the next tick.
    public func clampStretchedPauses() async {
        let now = now()
        let limit = now.addingTimeInterval(PauseLength.longest.seconds)
        let stretched = runState.plans.filter { _, history in (history.pausedUntil ?? .distantPast) > limit }.map(\.key)
        for id in stretched where config.plans.contains(where: { $0.id == id }) {
            _ = try? await updateHistory(id) { history in
                if let until = history.pausedUntil, until > limit { history.pausedUntil = limit }
            }
            restartLog("The clock went backwards during a pause, so plan \(id.uuidString) is now paused for a day from now")
        }
    }
}
