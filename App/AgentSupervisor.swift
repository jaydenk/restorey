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

    private(set) var health: AgentHealthState = .checking
    /// The latest status from the agent. Cleared whenever the health leaves `.healthy`, and fetched
    /// afresh on every return to it (`shouldRefetchStatus`).
    private(set) var status: AgentStatus?
    private(set) var lastHello: HelloReply?

    @ObservationIgnored let connection: AgentConnection
    @ObservationIgnored private let registration: AgentRegistration
    @ObservationIgnored private let installed: InstalledCopy
    @ObservationIgnored private let log: AppLog
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
    /// The start of the current run of failed heartbeats from an `enabled` agent (see
    /// `AgentHealthPolicy.unreachableGrace`).
    @ObservationIgnored private var unreachableSince: Date?
    @ObservationIgnored private var drainRetryDelay: TimeInterval = AgentHealthPolicy.heartbeatInterval

    init(installed: InstalledCopy, identity: Identity, log: AppLog, defaults: UserDefaults = .standard) {
        self.installed = installed
        self.log = log
        self.defaults = defaults
        registration = AgentRegistration(installed: installed, identity: identity, defaults: defaults)
        connection = AgentConnection(installed: installed, identity: identity)
        let info = Bundle.main.infoDictionary ?? [:]
        request = HelloRequest(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown")
        lastRepairs = loadRepairRecords()
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
        guard !busy, health != .damaged else { return }
        busy = true
        log.info("Restarting the agent at the user's request")
        Task { await reregister(reachable: lastHello != nil) }
    }

    func openLoginItems() {
        registration.openLoginItems()
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
        // No point asking an agent that isn't registered. Stamped before asking: an agent that is stopped
        // rather than dead only fails at the call timeout, which mustn't stretch the grace.
        let askedAt = Date()
        let beat = smStatus == .enabled ? await helloWithRetry() : .unreachable
        guard !busy else { return }
        if case .ok(let reply) = beat { lastHello = reply } else { lastHello = nil }
        if smStatus == .enabled, beat == .unreachable {
            if unreachableSince == nil { unreachableSince = askedAt }
        } else {
            unreachableSince = nil
        }

        let input = AgentHealthInput(
            smStatus: smStatus, heartbeat: beat, expectedExecutablePrefix: installed.helpersPrefix,
            appVersion: request.appVersion, appBuild: request.appBuild,
            storedPlistHash: registration.storedPlistHash, currentPlistHash: plistHash,
            executableFingerprintOnDisk: lastHello.flatMap(Self.fingerprintOnDisk),
            lastRepairs: lastRepairs, unreachableSince: unreachableSince,
            // Only an unreachable agent would be unregistered undrained, so only then is the process table read.
            resticRunningUnderAgent: unreachableSince != nil
                && resticRunsUnderAgent(helpersPrefix: installed.helpersPrefix),
            now: Date())
        let action = decideAgentHealth(input)
        if action != lastAction {
            log.info("Agent health: \(describe(input)) → \(action)")
            if action == .waitForRunningRestic {
                log.info("Not re-registering the unreachable agent: a restic it started is still running, and unregister() without a drain would kill it. Checking again at each heartbeat")
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
                log.info("Registered the agent; status is now \(registration.status)")
                set(.checking)
            } catch {
                let failure = AgentHealthState.failed(
                    "Restorey couldn't register its background agent: \(error.localizedDescription)")
                // Retried every heartbeat; logged once per distinct failure.
                if health != failure { log.error("Couldn't register the agent: \(error)") }
                set(failure)
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
        case .waitForUpdate:
            await waitForUpdate()
        case .waitForRunningRestic:
            // Re-decided at every heartbeat; `heartbeat` logs why when the action begins.
            set(.notRunning(reachable: false))
        case .showSwitchedOff:
            set(.switchedOff)
        case .showNotRunning:
            if case .ok = heartbeat { set(.notRunning(reachable: true)) } else { set(.notRunning(reachable: false)) }
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
                lastHello = reply
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
    /// registration, a changed plist and a job launchd removed. The caller has set `busy`.
    private func reregister(reachable: Bool) async {
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
            set(.failed("Restorey couldn't register its background agent: \(error.localizedDescription)"))
        }
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

    private func received(_ status: AgentStatus) {
        // By the agent's sequence number, not its clock, which can go backwards (final review M1).
        guard status.supersedes(self.status) else { return }
        self.status = status
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
