import Foundation
import RestoreyCore

/// Why the scheduler was asked to look again before its next minute.
public enum NudgeReason: Sendable, Equatable {
    /// The Mac woke from sleep: wait for the network (at most `wakeNetworkTimeout`), then catch up.
    case wake
    /// A volume was mounted at this path: plans skipped because it was missing run now.
    case volumeMounted(String)
    /// A plan's settings, recovery kit confirmation or pause changed.
    case configChanged
    case manual
}

/// What the scheduler needs from the plan runner. `PlanRunner` conforms; the tests use a fake.
public protocol SchedulerRunner: Sendable {
    /// Finishes recovery from the last agent's exit. Called once before the first tick.
    func recoverAfterStart() async
    /// Every plan with its history; empty when nothing may run (the config-error state).
    func scheduleEntries() async -> [(plan: Plan, history: PlanRunHistory)]
    /// Runs one backup. Throws only when the run can't be registered (draining, already running…).
    func runBackup(planID: UUID, trigger: RunTrigger) async throws -> RunRecord
    /// Pushes the status to the app if time alone has changed a plan's phase.
    func refreshStatus() async
}

/// Decides when each plan backs up (spec §5.5). Every minute, and on every nudge, it starts each plan
/// that `nextRunDate` says is due. A tick never waits for a run: each run is its own task. A plan never
/// has two runs from the scheduler at once; different plans run at the same time, and the repository
/// queue serialises those that share a repository.
///
/// Missed runs, runs after a pause, and runs after waking or a volume mounting are catch-ups; a run
/// after a lock is a retry. When the runner refuses because the agent is draining, the scheduler stops
/// for good (the agent is about to exit). Any other refusal is logged once per plan per reason.
public actor SchedulerCore {
    public static let tickInterval: Duration = .seconds(60)
    /// How long a wake waits for the network before catching up anyway.
    public static let wakeNetworkTimeout: Duration = .seconds(120)
    /// A run this late (seconds) is a catch-up: the scheduler wasn't running when it fell due.
    static let catchUpLateness: TimeInterval = 120

    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let runner: any SchedulerRunner
    private let waitForNetwork: @Sendable () async -> Void
    private let log: @Sendable (String) -> Void

    /// What nudges asked of the next tick.
    private struct Requests {
        /// Every plan that runs is a catch-up (a wake).
        var catchUpAll = false
        /// These plans run now even if not yet due, as catch-ups, provided their newest record is still
        /// a backup skipped for this reason when the tick reads them: skipped for a volume that has now
        /// mounted, or for no network before a wake or start-up.
        var forced: [UUID: SkipReason] = [:]
    }

    /// The scheduler's runs in progress, by plan.
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// Plans whose run ended while a tick was reading the plans: what it read may predate that run.
    private var endedDuringRead: Set<UUID> = []
    private var isReading = false
    /// The last refusal logged for each plan, so it is logged once rather than every minute.
    private var reported: [UUID: String] = [:]
    /// While `run()` waits for recovery, ticks and nudges are dropped; the first tick follows it.
    private var recovering = false
    public private(set) var isStopped = false
    private var tickInProgress = false
    private var tickAgain = false
    private var pending = Requests()
    /// Wakes (and start-up) waiting for the network.
    private var wakesWaiting = 0
    /// The loop's sleep between ticks, so stopping can end it at once.
    private var pause: Task<Void, any Error>?

    /// - Parameters:
    ///   - waitForNetwork: returns once the network path is satisfied. It must return when cancelled.
    ///   - log: lines for the agent's log.
    public init(
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date,
        runner: any SchedulerRunner,
        waitForNetwork: @escaping @Sendable () async -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.clock = clock
        self.now = now
        self.runner = runner
        self.waitForNetwork = waitForNetwork
        self.log = log
    }

    /// Calls `recoverAfterStart()`, then waits for the network as a wake does (at most
    /// `wakeNetworkTimeout`), then ticks every `tickInterval` until stopped or cancelled. Without the
    /// wait, the first tick after login would skip every due plan for no network while the path is
    /// still unknown or coming up, and move its first backup an hour on.
    public func run() async {
        recovering = true
        await runner.recoverAfterStart()
        recovering = false
        var first = true
        while !isStopped && !Task.isCancelled {
            if first {
                first = false
                await afterNetwork()
            } else {
                await tick()
            }
            guard !isStopped else { return }
            let clock = clock
            let pause = Task { try await clock.sleep(for: Self.tickInterval) }
            self.pause = pause
            let slept = await withTaskCancellationHandler {
                (try? await pause.value) != nil
            } onCancel: {
                pause.cancel()
            }
            self.pause = nil
            if !slept { return }
        }
    }

    /// Starts every due plan that isn't already running.
    public func tick() async {
        await tick(Requests())
    }

    /// Looks again now. A wake first waits for the network, for at most `wakeNetworkTimeout`, and then
    /// also runs plans last skipped for no network. A volume mounting runs the plans last skipped
    /// because it wasn't mounted, even if they aren't due.
    public func nudge(reason: NudgeReason) async {
        guard !recovering, !isStopped else { return }
        switch reason {
        case .wake:
            await afterNetwork(catchUpAll: true)
        case .volumeMounted(let path):
            let mounted = (path as NSString).standardizingPath
            let skipped = await plans(skippedFor: { reason in
                if case .volumeNotMounted(let volume) = reason { "/Volumes/\(volume)" == mounted } else { false }
            })
            await tick(Requests(forced: skipped))
        case .configChanged, .manual:
            await tick()
        }
    }

    /// Waits for the network (at most `wakeNetworkTimeout`), holding back other ticks meanwhile, then
    /// ticks, also running plans last skipped for no network. Holding back matters because a run before
    /// the network is back is skipped for no network, which also moves the plan's next run an hour on;
    /// a tick that slipped in before this began (just after waking) may have done exactly that.
    private func afterNetwork(catchUpAll: Bool = false) async {
        wakesWaiting += 1
        await networkOrTimeout()
        wakesWaiting -= 1
        let skipped = await plans(skippedFor: { $0 == .noNetwork })
        await tick(Requests(catchUpAll: catchUpAll, forced: skipped))
    }

    /// The plans whose newest record is a backup skipped for a reason that `matches`, with that reason.
    private func plans(skippedFor matches: (SkipReason) -> Bool) async -> [UUID: SkipReason] {
        var found: [UUID: SkipReason] = [:]
        for (plan, history) in await runner.scheduleEntries() {
            if let reason = Self.skipReason(history), matches(reason) { found[plan.id] = reason }
        }
        return found
    }

    /// Why the newest record was skipped, if it is a skipped backup.
    private static func skipReason(_ history: PlanRunHistory) -> SkipReason? {
        guard let latest = history.recent.first, latest.operation == .backup,
            case .skipped(let reason) = latest.outcome
        else { return nil }
        return reason
    }

    /// Waits for every run the scheduler has started to finish. For tests.
    func runsFinished() async {
        while let task = inFlight.values.first { await task.value }
    }

    // MARK: Ticks

    /// One tick at a time: a tick asked for during one runs straight after it, with fresh plans.
    private func tick(_ requests: Requests) async {
        guard !recovering, !isStopped else { return }
        pending.catchUpAll = pending.catchUpAll || requests.catchUpAll
        pending.forced.merge(requests.forced) { _, new in new }
        // A wake is waiting for the network; its tick follows and takes these requests with it.
        guard wakesWaiting == 0 else { return }
        guard !tickInProgress else {
            tickAgain = true
            return
        }
        tickInProgress = true
        defer { tickInProgress = false }
        repeat {
            tickAgain = false
            let requests = pending
            pending = Requests()
            await runner.refreshStatus()
            isReading = true
            endedDuringRead = []
            let entries = await runner.scheduleEntries()
            isReading = false
            let now = now()
            for (plan, history) in entries where inFlight[plan.id] == nil && !endedDuringRead.contains(plan.id) {
                let next = nextRunDate(plan: plan, history: history, now: now)
                // A forced plan is checked again against this read: it runs only if its newest record is
                // still that skip (a run may have finished since the nudge looked), and never while
                // paused or when it may not run at all.
                let forced = requests.forced[plan.id].map { $0 == Self.skipReason(history) } == true
                    && next != .distantFuture && !(history.pausedUntil.map { $0 > now } ?? false)
                guard next <= now || forced else { continue }
                let catchUp = requests.catchUpAll || forced
                start(plan, trigger: catchUp ? .catchUp : Self.trigger(plan: plan, history: history, now: now))
            }
        } while tickAgain && !isStopped
    }

    private func start(_ plan: Plan, trigger: RunTrigger) {
        let id = plan.id
        let runner = runner
        inFlight[id] = Task {
            let result: Result<RunRecord, any Error>
            do {
                result = .success(try await runner.runBackup(planID: id, trigger: trigger))
            } catch {
                result = .failure(error)
            }
            self.ended(plan, result)
        }
    }

    private func ended(_ plan: Plan, _ result: Result<RunRecord, any Error>) {
        inFlight[plan.id] = nil
        if isReading { endedDuringRead.insert(plan.id) }
        switch result {
        case .success:
            reported[plan.id] = nil
        case .failure(AgentError.draining):
            stop()
        case .failure(let error):
            let reason = (error as? AgentError)?.message ?? "\(error)"
            guard reported[plan.id] != reason else { return }
            reported[plan.id] = reason
            log("The scheduler couldn't start a backup of \(plan.name) (plan \(plan.id.uuidString)): \(reason)")
        }
    }

    private func stop() {
        guard !isStopped else { return }
        isStopped = true
        pause?.cancel()
        log("The agent is finishing up before a restart, so no more backups will be scheduled")
    }

    // MARK: Decisions

    /// Why a due plan runs: a retry after a lock, a catch-up after a pause ran out or a run missed by
    /// more than `catchUpLateness`, otherwise scheduled.
    static func trigger(plan: Plan, history: PlanRunHistory, now: Date) -> RunTrigger {
        if let latest = history.recent.first, latest.operation == .backup, latest.outcome == .locked { return .retry }
        if let until = history.pausedUntil, until <= now { return .catchUp }
        guard let last = history.lastAttemptAt else { return .scheduled }
        let interval: TimeInterval
        switch plan.schedule {
        case .interval(let seconds): interval = TimeInterval(seconds)
        }
        let late = now.timeIntervalSince(min(last, now).addingTimeInterval(interval))
        return late > catchUpLateness ? .catchUp : .scheduled
    }

    // MARK: Wake

    /// Returns when the network is satisfied or after `wakeNetworkTimeout`, whichever comes first, and
    /// cancels the other.
    private func networkOrTimeout() async {
        let clock = clock
        let waitForNetwork = waitForNetwork
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await waitForNetwork() }
            group.addTask { try? await clock.sleep(for: Self.wakeNetworkTimeout) }
            await group.next()
            group.cancelAll()
        }
    }
}

extension PlanRunner: SchedulerRunner {
    public func scheduleEntries() async -> [(plan: Plan, history: PlanRunHistory)] {
        await deps.state.allRunInputs()
    }

    public func refreshStatus() async {
        await deps.state.pushStatusIfChanged()
    }
}
