import Foundation
import Observation
import RestoreyCore

/// Keeps the agent installed, current and alive (spec §6.2 and §8): a `hello` every 10 s, the repair
/// table in `decideAgentHealth`, and the repairs themselves. Exists only for the installed copy.
@MainActor
@Observable
final class AgentSupervisor {
    /// The last automatic repair of each kind, as `[RepairRecord]` JSON in the app's `UserDefaults`.
    static let repairRecordKey = "lastAgentRepairs"
    /// When an automatic re-registration last stopped a hung backup (`backupStoppedByRepairAt`), as a `Date`.
    static let backupStoppedByRepairKey = "backupStoppedByRepairAt"

    private(set) var health: AgentHealthState = .checking
    /// The latest status from the agent. Cleared whenever the health leaves `.healthy`, and fetched
    /// afresh on every return to it (`shouldRefetchStatus`).
    private(set) var status: AgentStatus?
    /// The latest status accepted, never cleared: what the menu shows as "Last known" while the agent is down
    /// (`menuStatus`). Also what a new status is ordered against.
    private(set) var lastKnownStatus: AgentStatus?
    private(set) var lastHello: HelloReply?
    /// When the app last re-registered an agent that hadn't answered for `AgentHealthPolicy.hungResticCap`, stopping
    /// the backup it was running; the menu says so until a plan backs up, or tries to, since
    /// (`MenuPresentation.backupStoppedNoteStands`). Kept in `UserDefaults` beside the repair records.
    private(set) var backupStoppedByRepairAt: Date?
    /// Ruling R76: agent processes seen replaced. A status from one of them is dropped.
    var retiredAgentRuns: Set<UUID> { runs.retired }

    let identity: Identity

    @ObservationIgnored let connection: AgentConnection
    @ObservationIgnored private let registration: AgentRegistration
    @ObservationIgnored private let installed: InstalledCopy
    /// The app's log, also handed to the windows' views (`EnvironmentValues.appLog`).
    @ObservationIgnored let log: AppLog
    @ObservationIgnored private let request: HelloRequest
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [() -> Void] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// True while a registration or repair is in progress: heartbeats wait for it.
    @ObservationIgnored private var busy = false
    /// True while a heartbeat runs, so the loop and `checkSoon` never decide twice at once.
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var lastRepairs: [RepairRecord] = []
    @ObservationIgnored private var lastAction: AgentHealthAction?
    /// After a drain call fails, re-registration waits until then (10 s doubling to 10 min).
    @ObservationIgnored private var drainRetryAfter: Date?
    /// The current run of failed heartbeats from an `enabled` agent, timed in awake time (see
    /// `AgentHealthPolicy.unreachableGrace` and `hungResticCap`).
    @ObservationIgnored private var unreachable = UnreachableRun()
    /// Stops while the Mac sleeps and ignores wall-clock changes, so neither counts towards the grace or the cap.
    @ObservationIgnored private let awakeOrigin = SuspendingClock().now
    /// The last `register()` failure logged, so one repeated every heartbeat is logged once.
    @ObservationIgnored private var lastRegisterFailure: String?
    @ObservationIgnored private var drainRetryDelay: TimeInterval = AgentHealthPolicy.heartbeatInterval
    @ObservationIgnored private var runs = AgentRunTracker()

    init(installed: InstalledCopy, identity: Identity, log: AppLog, defaults: UserDefaults = .standard) {
        self.installed = installed
        self.identity = identity
        self.log = log
        self.defaults = defaults
        registration = AgentRegistration(installed: installed, identity: identity, defaults: defaults)
        connection = AgentConnection(installed: installed, identity: identity, log: log)
        let info = Bundle.main.infoDictionary ?? [:]
        request = HelloRequest(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown")
        lastRepairs = loadRepairRecords()
        backupStoppedByRepairAt = defaults.object(forKey: Self.backupStoppedByRepairKey) as? Date
        connection.onStatus = { [weak self] status in self?.received(status) }
    }

    /// Called on every change of health or status.
    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    func start() {
        guard loop == nil else { return }
        log.info("App \(request.appVersion) (\(request.appBuild)) started at \(installed.bundleURL.path)")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeat()
                try? await Task.sleep(for: .seconds(AgentHealthPolicy.heartbeatInterval))
            }
        }
    }

    // MARK: User actions

    /// "Restart agent": drain if reachable, then re-register. The user asked, so the hourly limit on
    /// automatic repairs doesn't apply, but it counts as one. Never offered for a damaged install, where
    /// `unregister()` would remove a working registration that `register()` can't put back.
    func restartAgent() {
        guard !busy, health != .damaged, health != .signatureUntrusted else { return }
        busy = true
        log.info("Restarting the agent at the user's request")
        Task { await reregister(reachable: lastHello != nil) }
    }

    func openLoginItems() {
        registration.openLoginItems()
    }

    /// A hello outside the heartbeat, for setup's permissions step: the notification answer the agent holds can
    /// change in System Settings at any time, and the step shows it within its 2 s poll. Only the hello's
    /// reply is noted; the heartbeat still decides the agent's health.
    func refreshHello() async {
        guard case .success(let reply) = await connection.hello(request) else { return }
        noteHello(reply)
    }

    // MARK: Heartbeat

    private func heartbeat() async {
        guard !busy, !checking else { return }
        checking = true
        defer { checking = false }
        let plistHash: String
        do {
            plistHash = try registration.currentPlistHash()
        } catch {
            if health != .damaged { log.error("Can't read the embedded agent plist: \(error)") }
            set(.damaged)
            return
        }
        let smStatus = registration.status
        // No point asking an agent that isn't registered, or any agent while the connection admits none (Ruling T7-1).
        // Stamped before asking: an agent that is stopped rather than dead only fails at the call timeout, which
        // mustn't stretch the grace.
        let refusesEveryAgent = connection.refusesEveryAgent
        let askedAt = awakeTime()
        let beat = smStatus == .enabled && !refusesEveryAgent ? await helloWithRetry() : .unreachable
        guard !busy else { return }
        // `SMAppService.status` (`smStatus`) is read afresh above at every heartbeat, so the user switching the
        // agent off in Login Items shows within one heartbeat while the app runs.
        if case .ok(let reply) = beat { noteHello(reply) } else { noteHello(nil) }
        let unreachableAwakeFor = unreachable.heartbeat(
            failing: smStatus == .enabled && !refusesEveryAgent && beat == .unreachable, askedAt: askedAt, now: awakeTime())

        let input = AgentHealthInput(
            smStatus: smStatus, heartbeat: beat, expectedExecutablePrefix: installed.helpersPrefix,
            appVersion: request.appVersion, appBuild: request.appBuild,
            storedPlistHash: registration.storedPlistHash, currentPlistHash: plistHash,
            executableFingerprintOnDisk: lastHello.flatMap(Self.fingerprintOnDisk),
            lastRepairs: lastRepairs, unreachableAwakeFor: unreachableAwakeFor,
            // Only an unreachable agent would be unregistered undrained, so only then is the process table read.
            resticRunningUnderAgent: unreachableAwakeFor != nil
                && resticRunsUnderAgent(helpersPrefix: installed.helpersPrefix),
            connectionRefusesEveryAgent: refusesEveryAgent,
            now: Date())
        let action = decideAgentHealth(input)
        if action != lastAction {
            log.info("Agent health: \(describe(input)) → \(action)")
            if action == .waitForRunningRestic {
                log.info("Not re-registering the unreachable agent: a restic it started is still running, and unregister() without a drain would kill it. Checking again at each heartbeat, for up to \(Int(AgentHealthPolicy.hungResticCap / 60)) minutes")
            }
            lastAction = action
        }
        await perform(action, heartbeat: beat)
    }

    /// One retry after 2 s, so the 0.4 s KeepAlive gap after an agent crash isn't reported as a fault.
    private func helloWithRetry() async -> AgentHeartbeat {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if case .success(let reply) = await connection.hello(request) { return .ok(reply) }
        }
        return .unreachable
    }

    private func perform(_ action: AgentHealthAction, heartbeat: AgentHeartbeat) async {
        switch action {
        case .none:
            set(.healthy)
            // Normally fetched by the transition into .healthy; retried here if that fetch failed.
            if status == nil { _ = await connection.status() }
        case .register:
            busy = true
            do {
                try registration.register()
                lastRegisterFailure = nil
                log.info("Registered the agent; status is now \(registration.status)")
                set(.checking)
            } catch {
                let sentence = "Restorey couldn’t register its background process: \(error.localizedDescription)"
                // Retried every heartbeat; logged once per distinct failure.
                if lastRegisterFailure != sentence { log.error("Couldn't register the agent: \(error)") }
                lastRegisterFailure = sentence
                set(healthAfterFailedRegistration(sentence, connectionRefusesEveryAgent: connection.refusesEveryAgent))
            }
            busy = false
            checkSoon()
        case .restartAfterDrain:
            recordRepair(.restart)
            await restart()
        case .reregisterAfterDrain:
            if let retryAfter = drainRetryAfter, Date() < retryAfter { return }
            busy = true
            if case .ok = heartbeat { await reregister(reachable: true) } else { await reregister(reachable: false) }
        case .reregisterStoppingBackup:
            busy = true
            log.error("The agent hasn't answered for \(Int(AgentHealthPolicy.hungResticCap / 60)) minutes while a restic it started is still running: re-registering it, which stops that backup")
            await reregister(reachable: false, stoppingBackup: true)
        case .waitForUpdate:
            await waitForUpdate()
        case .waitForRunningRestic:
            // Re-decided at every heartbeat; `heartbeat` logs why when the action begins.
            set(.notRunning(reachable: false))
        case .showSwitchedOff:
            set(.switchedOff)
        case .showNotRunning:
            if case .ok = heartbeat { set(.notRunning(reachable: true)) } else { set(.notRunning(reachable: false)) }
        case .showSignatureUntrusted:
            // `AgentConnection` logged why when it was made; nothing is repaired, so nothing more to log.
            set(.signatureUntrusted)
        }
    }

    /// Spike H6: drain, let launchd's KeepAlive start the new binary, then wait for the version and build
    /// to match.
    private func restart() async {
        busy = true
        defer { busy = false; checkSoon() }
        set(.updating)
        log.info("Asking the agent to finish any run in progress and exit")
        guard case .success = await logged(connection.prepareForRestart(), "prepareForRestart") else { return }
        log.info("The agent has finished; waiting for launchd to start it again")
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(2))
            if case .success(let reply) = await connection.hello(request) {
                noteHello(reply)
                if agentIsCurrent(
                    reply, appVersion: request.appVersion, appBuild: request.appBuild,
                    executableFingerprintOnDisk: Self.fingerprintOnDisk(reply)) {
                    log.info("The agent restarted and now runs \(reply.agentVersion) (\(reply.agentBuild))")
                    return
                }
            }
        }
        log.error("The agent didn't come back as \(request.appVersion) (\(request.appBuild)) within 60 s")
    }

    /// The agent is already draining: from a drain an earlier app started, or left drained by an app that
    /// quit half-way through a re-registration. Ask it to restart once drained (it replies at once if it
    /// already is), so it can't stay drained and refusing everything.
    private func waitForUpdate() async {
        busy = true
        defer { busy = false; checkSoon() }
        set(.waitingForUpdate)
        _ = await logged(connection.prepareForRestart(), "prepareForRestart (agent already draining)")
    }

    /// Spike phase B: drain without exiting, then `unregister()` then `register()`. Fixes a re-pointed
    /// registration, a changed plist and a job launchd removed. The caller has set `busy`. `stoppingBackup`: the agent
    /// is unreachable with a restic it started still running, which `unregister()` stops; noted for the menu once it has.
    private func reregister(reachable: Bool, stoppingBackup: Bool = false) async {
        defer { busy = false; checkSoon() }
        if reachable {
            // unregister() stops the agent and kills restic mid-run, so drain first. The agent stays up
            // once drained: exiting would let KeepAlive start a fresh one for unregister() to kill.
            set(.updating)
            log.info("Asking the agent to finish any run in progress before re-registering it")
            guard case .success = await logged(connection.prepareForReregistration(), "prepareForReregistration")
            else {
                // Never unregister an agent that may still be running a backup. Try again later.
                drainRetryAfter = Date().addingTimeInterval(drainRetryDelay)
                log.info("Not re-registering; will try again in \(Int(drainRetryDelay)) s")
                drainRetryDelay = min(drainRetryDelay * 2, 600)
                set(.notRunning(reachable: true))
                return
            }
        }
        drainRetryAfter = nil
        drainRetryDelay = AgentHealthPolicy.heartbeatInterval
        recordRepair(.reregister)
        set(.checking)
        do {
            try await registration.unregister()
            if stoppingBackup { noteBackupStoppedByRepair(Date()) }
        } catch {
            log.error("unregister() failed: \(error)")
            if reachable {
                // The drained agent would otherwise stay up refusing everything: let it exit, and
                // KeepAlive starts it again. The next heartbeat decides what to do.
                _ = await logged(connection.prepareForRestart(), "prepareForRestart after a failed unregister()")
                connection.reset()
                return
            }
        }
        connection.reset()
        do {
            try registration.register()
            log.info("Re-registered the agent; status is now \(registration.status)")
        } catch {
            log.error("Couldn't re-register the agent: \(error)")
            set(healthAfterFailedRegistration(
                "Restorey couldn’t register its background process: \(error.localizedDescription)",
                connectionRefusesEveryAgent: connection.refusesEveryAgent))
        }
    }

    /// Awake time since the supervisor first asked, for `UnreachableRun`.
    private func awakeTime() -> Duration {
        awakeOrigin.duration(to: SuspendingClock().now)
    }

    /// The fingerprint of the file now at the path the agent reports.
    private static func fingerprintOnDisk(_ reply: HelloReply) -> String? {
        ExecutableFingerprint.of(URL(fileURLWithPath: reply.executablePath))
    }

    private func logged<T>(_ result: Result<T, AgentCallError>, _ name: String) -> Result<T, AgentCallError> {
        if case .failure(let error) = result { log.error("\(name) failed: \(error)") }
        return result
    }

    /// The next heartbeat in 2 s rather than 10, after anything that changes the agent.
    private func checkSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.heartbeat()
        }
    }

    // MARK: Repair record

    /// Ruling R51: persisted, so a relaunch within the hour doesn't repair again. Records from another
    /// version or build are cleared, so a new build restarts the agent at once.
    private func loadRepairRecords() -> [RepairRecord] {
        guard let data = defaults.data(forKey: Self.repairRecordKey),
              let records = try? XPCCoding.decode([RepairRecord].self, from: data)
        else {
            defaults.removeObject(forKey: Self.repairRecordKey)
            return []
        }
        let current = records.filter { $0.appVersion == request.appVersion && $0.appBuild == request.appBuild }
        if current.count != records.count { saveRepairRecords(current) }
        return current
    }

    private func recordRepair(_ kind: RepairKind) {
        let record = RepairRecord(kind: kind, at: Date(), appVersion: request.appVersion, appBuild: request.appBuild)
        lastRepairs = lastRepairs.filter { $0.kind != kind } + [record]
        saveRepairRecords(lastRepairs)
    }

    private func saveRepairRecords(_ records: [RepairRecord]) {
        if let data = try? XPCCoding.encode(records) { defaults.set(data, forKey: Self.repairRecordKey) }
    }

    /// Persisted, so the menu still says so after a relaunch; nil clears it. The menu shows it only once the agent is
    /// healthy again, and that change notifies; a clear happens in `received`, which does.
    private func noteBackupStoppedByRepair(_ at: Date?) {
        backupStoppedByRepairAt = at
        if let at { defaults.set(at, forKey: Self.backupStoppedByRepairKey) } else {
            defaults.removeObject(forKey: Self.backupStoppedByRepairKey)
        }
    }

    // MARK: State

    private func set(_ next: AgentHealthState) {
        let previous = health
        guard previous != next else { return }
        health = next
        // Whatever was shown may be from before the change: drop it, and fetch afresh on recovery.
        if next != .healthy || shouldRefetchStatus(previous: previous, next: next) { status = nil }
        notify()
        if shouldRefetchStatus(previous: previous, next: next) {
            Task { [weak self] in _ = await self?.connection.status() }
        }
    }

    /// A new agent run in a hello retires the run before it (R76). The menu shows the notification banner from the
    /// hello, so a change there is a change to show.
    private func noteHello(_ reply: HelloReply?) {
        if let reply { runs.helloReported(reply.agentRun) }
        let notificationsChanged = reply?.notificationsAuthorised != lastHello?.notificationsAuthorised
        lastHello = reply
        if notificationsChanged { notify() }
    }

    private func received(_ status: AgentStatus) {
        // By the agent's sequence number, not its clock, which can go backwards (final review M1), and never from
        // an agent process already replaced (R76). Ordered against the last status accepted, which outlives
        // `status` being cleared, so a late reply can't slip in while the health changes.
        guard runs.shouldAccept(status, over: lastKnownStatus) else {
            if let run = status.agentRun, runs.retired.contains(run) {
                log.info("Ignored a late status from agent run \(run.uuidString), which has been replaced")
            }
            return
        }
        runs.statusAccepted(status.agentRun)
        self.status = status
        lastKnownStatus = status
        if let stoppedAt = backupStoppedByRepairAt,
           !MenuPresentation.backupStoppedNoteStands(stoppedAt: stoppedAt, status: status) {
            log.info("A plan has backed up or tried to since the repair that stopped a backup: the menu no longer says so")
            noteBackupStoppedByRepair(nil)
        }
        notify()
    }

    private func notify() {
        for observer in observers { observer() }
    }

    private func describe(_ input: AgentHealthInput) -> String {
        let beat: String = switch input.heartbeat {
        case .ok(let reply): "\(reply.agentVersion) (\(reply.agentBuild)) at \(reply.executablePath)"
            + (reply.draining ? ", draining" : "")
            + (reply.executableFingerprint == input.executableFingerprintOnDisk ? "" : ", binary replaced since launch")
        case .unreachable: "unreachable"
        }
        return "\(input.smStatus), \(beat), app \(input.appVersion) (\(input.appBuild)), plist "
            + (input.storedPlistHash == input.currentPlistHash ? "unchanged" : "changed")
    }
}
