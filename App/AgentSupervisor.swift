import Foundation
import Observation
import RestoreyCore

/// Keeps the agent installed, current and alive (spec §6.2 and §8): a `hello` every 10 s, the repair
/// table in `decideAgentHealth`, and the repairs themselves. Exists only for the installed copy.
@MainActor
@Observable
final class AgentSupervisor {
    enum Health: Equatable {
        case checking
        case healthy
        /// Waiting for `prepareForRestart`: "Finishing the current backup before updating the agent".
        case updating
        case switchedOff
        /// `reachable` is true when the agent answers but a repair didn't fix it.
        case notRunning(reachable: Bool)
        /// Registering failed, or the embedded plist can't be read. The sentence is shown as is.
        case failed(String)
    }

    private(set) var health: Health = .checking
    /// The latest status from the agent; nil until the first one arrives.
    private(set) var status: AgentStatus?
    private(set) var lastHello: HelloReply?

    @ObservationIgnored let connection: AgentConnection
    @ObservationIgnored private let registration: AgentRegistration
    @ObservationIgnored private let installed: InstalledCopy
    @ObservationIgnored private let log: AppLog
    @ObservationIgnored private let request: HelloRequest
    @ObservationIgnored private var observers: [() -> Void] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// True while a registration or repair is in progress: heartbeats wait for it.
    @ObservationIgnored private var busy = false
    /// True while a heartbeat runs, so the loop and `checkSoon` never decide twice at once.
    @ObservationIgnored private var checking = false
    /// In memory only, so each launch of a new build gets its one repair straight away.
    @ObservationIgnored private var lastRepair: Date?
    @ObservationIgnored private var lastAction: AgentHealthAction?

    init(installed: InstalledCopy, identity: Identity, log: AppLog) {
        self.installed = installed
        self.log = log
        registration = AgentRegistration(installed: installed, identity: identity)
        connection = AgentConnection(installed: installed, identity: identity)
        let info = Bundle.main.infoDictionary ?? [:]
        request = HelloRequest(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown")
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
    /// automatic repairs doesn't apply, but it counts as one.
    func restartAgent() {
        guard !busy else { return }
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
            let failure = Health.failed("Restorey's background agent settings are missing from the app. Reinstall Restorey.")
            if health != failure { log.error("Can't read the embedded agent plist: \(error)") }
            set(failure)
            return
        }
        let smStatus = registration.status
        // No point asking an agent that isn't registered.
        let beat = smStatus == .enabled ? await helloWithRetry() : .unreachable
        guard !busy else { return }
        if case .ok(let reply) = beat { lastHello = reply } else { lastHello = nil }

        let input = AgentHealthInput(
            smStatus: smStatus, heartbeat: beat, expectedExecutablePrefix: installed.helpersPrefix,
            appBuild: request.appBuild, storedPlistHash: registration.storedPlistHash,
            currentPlistHash: plistHash,
            repairAttemptedRecently: lastRepair.map { Date().timeIntervalSince($0) < AgentHealthPolicy.repairInterval }
                ?? false)
        let action = decideAgentHealth(input)
        if action != lastAction {
            log.info("Agent health: \(describe(input)) → \(action)")
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
            if status == nil { _ = await connection.status() }
        case .register:
            busy = true
            do {
                try registration.register()
                log.info("Registered the agent; status is now \(registration.status)")
                set(.checking)
            } catch {
                let failure = Health.failed("Restorey couldn't register its background agent: \(error.localizedDescription)")
                // Retried every heartbeat; logged once per distinct failure.
                if health != failure { log.error("Couldn't register the agent: \(error)") }
                set(failure)
            }
            busy = false
            checkSoon()
        case .restartAfterDrain:
            lastRepair = Date()
            await restart()
        case .reregisterAfterDrain:
            if case .ok = heartbeat { await reregister(reachable: true) } else { await reregister(reachable: false) }
        case .showSwitchedOff:
            set(.switchedOff)
        case .showNotRunning:
            if case .ok = heartbeat { set(.notRunning(reachable: true)) } else { set(.notRunning(reachable: false)) }
        }
    }

    /// Spike H6: drain, let launchd's KeepAlive start the new binary, then wait for the builds to match.
    private func restart() async {
        busy = true
        defer { busy = false; checkSoon() }
        guard await drain() else { return }
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(2))
            if case .success(let reply) = await connection.hello(request) {
                lastHello = reply
                if reply.agentBuild == request.appBuild {
                    log.info("The agent restarted and now runs build \(reply.agentBuild)")
                    return
                }
            }
        }
        log.error("The agent didn't come back with build \(request.appBuild) within 60 s")
    }

    /// Spike phase B: drain if reachable, then `unregister()` then `register()`. Fixes a re-pointed
    /// registration, a changed plist and a job launchd removed.
    private func reregister(reachable: Bool) async {
        busy = true
        lastRepair = Date()
        defer { busy = false; checkSoon() }
        // unregister() stops the agent and kills restic mid-run, so drain first whenever we can.
        if reachable, !(await drain()) {
            log.info("The agent stopped answering while draining; re-registering anyway")
        }
        set(.checking)
        do {
            try await registration.unregister()
        } catch {
            // Already gone is fine: register() below is what matters.
            log.info("unregister() failed, continuing to register(): \(error)")
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

    /// Waits, with no timeout, for the agent to finish any run in flight. False if the agent couldn't be
    /// reached or refused.
    private func drain() async -> Bool {
        set(.updating)
        log.info("Asking the agent to finish any run in progress and exit")
        switch await connection.prepareForRestart() {
        case .success:
            log.info("The agent has finished; waiting for launchd to start it again")
            return true
        case .failure(let error):
            log.error("prepareForRestart failed: \(error)")
            return false
        }
    }

    /// The next heartbeat in 2 s rather than 10, after anything that changes the agent.
    private func checkSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.heartbeat()
        }
    }

    // MARK: State

    private func set(_ health: Health) {
        guard self.health != health else { return }
        self.health = health
        notify()
    }

    private func received(_ status: AgentStatus) {
        if let current = self.status, current.generatedAt > status.generatedAt { return }
        self.status = status
        notify()
    }

    private func notify() {
        for observer in observers { observer() }
    }

    private func describe(_ input: AgentHealthInput) -> String {
        let beat: String = switch input.heartbeat {
        case .ok(let reply): "build \(reply.agentBuild) at \(reply.executablePath)"
        case .unreachable: "unreachable"
        }
        return "\(input.smStatus), \(beat), app build \(input.appBuild), plist "
            + (input.storedPlistHash == input.currentPlistHash ? "unchanged" : "changed")
    }
}
