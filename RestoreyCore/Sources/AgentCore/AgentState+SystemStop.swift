import Foundation
import RestoreyCore
import Synchronization

/// launchd stopping the agent (Ruling R67), and the drain every stop and restart waits on.
extension AgentState {
    // MARK: The system stopping the agent (Ruling R67)

    /// The whole of `stopForSystem`, from SIGTERM to the exit: well under launchd's exit timeout, which is
    /// 5 s for a LaunchAgent on macOS 27 (`launchctl print gui/<uid>/<label>` reports "exit timeout = 5";
    /// launchd.plist(5) `ExitTimeOut` calls the default system-defined), after which launchd sends SIGKILL.
    public static let systemStopBudget: Duration = .milliseconds(4_000)
    /// How long restic gets to honour our SIGINT before SIGKILL when the system is stopping the agent. An
    /// honoured SIGINT took under a second in the alpha (Pause stopped restic in 0.8 s).
    public static let systemStopInterruptGrace: Duration = .milliseconds(2_500)
    /// How much of the budget is kept for the queued check-in pings.
    static let systemStopPingShare: Duration = .milliseconds(500)

    /// launchd is stopping the agent (logout, restart or shutdown). That is routine, not a failure: no new
    /// restic step or mutating call is accepted from now on, each run in flight is interrupted with
    /// `.systemStop` (restic gets SIGINT, removes its own lock and the run is committed `.stoppedBySystem`:
    /// no alert, no ping, retried after the short retry), and the state and queued pings are given the
    /// rest of `budget`. Runs that haven't ended by then are left to recovery, which records them
    /// `.interrupted`.
    ///
    /// - Parameter runner: the runner, which may not be attached yet (recovery's unlocks run before it is).
    /// - Returns: true when the caller should exit now; false when it is already exiting (a restart exit
    ///   is on its way) or another call is handling the stop, so the agent never exits twice.
    public func stopForSystem(
        runner: PlanRunner?, budget: Duration = systemStopBudget,
        interruptGrace: Duration = systemStopInterruptGrace
    ) async -> Bool {
        guard !isStoppingForSystem, !exited else { return false }
        isStoppingForSystem = true
        isDraining = true
        drainPurpose = .systemStop
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        restartLog("The system is stopping the agent (logout, restart or shutdown): stopping any restic in progress, then exiting")
        let runner = runner ?? self.runner
        await runner?.interruptAll(.systemStop, killAfter: interruptGrace)

        let idleBudget = max(deadline - clock.now - Self.systemStopPingShare, .zero)
        if await Self.bounded(idleBudget, { await self.waitUntilIdle() }) == nil {
            restartLog("A run hadn't ended when the agent had to exit; its next start records it as interrupted")
        }
        if let runner, await Self.bounded(max(deadline - clock.now, .zero), { await runner.pingsFlushed() }) == nil {
            restartLog("Exiting before every queued check-in ping was sent")
        }
        // A restart exit that fired meanwhile has the process on its way out already.
        guard !exited else { return false }
        exited = true
        restartLog("Exiting because the system asked the agent to stop")
        return true
    }

    private func waitUntilIdle() async {
        while !isIdle {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    func drain(_ purpose: DrainPurpose, pingBudget: Duration) async -> Bool {
        if drainPurpose?.exitsAfterwards != true { drainPurpose = purpose }
        isDraining = true
        while !isIdle {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        guard let runner else { return true }
        return await Self.bounded(pingBudget) { await runner.pingsFlushed() } != nil
    }

    /// How late a `bounded` budget may end.
    static let boundedTimerTolerance: Duration = .milliseconds(50)

    /// `work`'s result if it finishes within `budget`, otherwise nil. The work is not cancelled when it
    /// doesn't: it may be stuck in a call that can't be cancelled (another process's IPC, say).
    static func bounded<T: Sendable>(_ budget: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let settled = Mutex(false)
        let timer = Mutex<Task<Void, Never>?>(nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            func settle(_ value: T?) {
                guard settled.withLock({ let was = $0; $0 = true; return !was }) else { return }
                continuation.resume(returning: value)
            }
            timer.withLock {
                $0 = Task {
                    // An explicit tolerance, as for restic's SIGKILL timer: with none, the system may fire
                    // the timer late to coalesce wake-ups (measured at about 5% late), eating into the
                    // system stop's margin under launchd's exit timeout.
                    try? await Task.sleep(for: budget, tolerance: boundedTimerTolerance)
                    settle(nil)
                }
            }
            Task {
                let value = await work()
                settle(value)
                timer.withLock { $0?.cancel() }
            }
        }
    }

    private var isIdle: Bool { running.isEmpty && measuring.isEmpty && !writeInFlight && writeWaiters.isEmpty }

    /// Wakes every drainer; each re-checks `isIdle` and waits again if something is still going on.
    func wakeDrainersIfIdle() {
        guard isIdle, !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
