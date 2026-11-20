import Foundation

/// `SMAppService.Status`, without importing ServiceManagement here.
public enum AgentServiceStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    /// What a fresh install reads before its first `register()` (spike H3a).
    case notFound
}

/// The latest `hello`.
public enum AgentHeartbeat: Sendable, Equatable {
    case ok(HelloReply)
    case unreachable
}

/// The two kinds of automatic repair. The hourly limit is per kind: a restart (for a stale agent) is
/// often followed at once by a re-registration (for a changed plist), and each must still be allowed.
public enum RepairKind: String, Codable, Sendable, Equatable, CaseIterable {
    case restart
    case reregister
}

/// The last automatic repair of one kind, persisted in the app's `UserDefaults` so the hourly limit
/// survives a relaunch. A record from another app version or build doesn't count, so a new build
/// restarts the agent at once.
public struct RepairRecord: Codable, Sendable, Equatable {
    public var kind: RepairKind
    public var at: Date
    public var appVersion: String
    public var appBuild: String

    public init(kind: RepairKind, at: Date, appVersion: String, appBuild: String) {
        self.kind = kind
        self.at = at
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    /// Made by this version and build, and less than `AgentHealthPolicy.repairInterval` ago. A record in
    /// the future (the clock moved back) doesn't count, so it can't block repairs for longer than that.
    public func isRecent(appVersion: String, appBuild: String, now: Date) -> Bool {
        guard self.appVersion == appVersion, self.appBuild == appBuild else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < AgentHealthPolicy.repairInterval
    }
}

/// Everything `decideAgentHealth` looks at. The app gathers it on every heartbeat.
public struct AgentHealthInput: Sendable, Equatable {
    public var smStatus: AgentServiceStatus
    public var heartbeat: AgentHeartbeat
    /// `<app bundle>/Contents/Helpers/`: the agent binary must be inside the asking app's bundle.
    public var expectedExecutablePrefix: String
    public var appVersion: String
    public var appBuild: String
    /// The SHA-256 of the embedded launchd plist at the last successful `register()`, if any.
    public var storedPlistHash: String?
    public var currentPlistHash: String
    /// `ExecutableFingerprint` of the file at the heartbeat's `executablePath` now, if readable.
    public var executableFingerprintOnDisk: String?
    /// The last repair of each kind (at most one per kind).
    public var lastRepairs: [RepairRecord]
    /// How long an `enabled` agent's heartbeats have kept failing, in time the Mac was awake (`UnreachableRun`); `nil`
    /// while it answers. Sleep and wall-clock changes don't count, so a hello that failed just before a long sleep
    /// can't make the first failure after waking look like hours of silence.
    public var unreachableAwakeFor: TimeInterval?
    /// A restic from this app's `Contents/Helpers` is running under the agent (`resticRunsUnderAgent`).
    /// Only asked for an unreachable agent, the one case that would be unregistered without a drain.
    public var resticRunningUnderAgent: Bool
    /// The app's connection admits no agent (`AgentPeerCheck.refuseAll`): its own signature can't be trusted, so
    /// every hello fails however healthy the agent is (Ruling T7-1).
    public var connectionRefusesEveryAgent: Bool
    public var now: Date

    public init(
        smStatus: AgentServiceStatus, heartbeat: AgentHeartbeat, expectedExecutablePrefix: String,
        appVersion: String, appBuild: String, storedPlistHash: String?, currentPlistHash: String,
        executableFingerprintOnDisk: String?, lastRepairs: [RepairRecord], unreachableAwakeFor: TimeInterval? = nil,
        resticRunningUnderAgent: Bool = false, connectionRefusesEveryAgent: Bool = false, now: Date
    ) {
        self.smStatus = smStatus
        self.heartbeat = heartbeat
        self.expectedExecutablePrefix = expectedExecutablePrefix
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.storedPlistHash = storedPlistHash
        self.currentPlistHash = currentPlistHash
        self.executableFingerprintOnDisk = executableFingerprintOnDisk
        self.lastRepairs = lastRepairs
        self.unreachableAwakeFor = unreachableAwakeFor
        self.resticRunningUnderAgent = resticRunningUnderAgent
        self.connectionRefusesEveryAgent = connectionRefusesEveryAgent
        self.now = now
    }

    /// An automatic repair of this kind by this build ran within the last hour.
    public func repairAttemptedRecently(_ kind: RepairKind) -> Bool {
        lastRepairs.contains { $0.kind == kind && $0.isRecent(appVersion: appVersion, appBuild: appBuild, now: now) }
    }
}

public enum AgentHealthAction: Sendable, Equatable {
    case none
    /// `register()`.
    case register
    /// `prepareForReregistration` (drain, don't exit), then `unregister()` then `register()`. An unreachable
    /// agent has nothing to drain.
    case reregisterAfterDrain
    /// `reregisterAfterDrain` for an agent that hasn't answered for `AgentHealthPolicy.hungResticCap` while a restic
    /// it started is running: the undrained `unregister()` stops that backup (owner, 20 Nov 2026). Under the same
    /// hourly limit as any re-registration.
    case reregisterStoppingBackup
    /// `prepareForRestart`; launchd's `KeepAlive` starts the new binary.
    case restartAfterDrain
    /// The agent doesn't answer, but a restic it started is running, so an undrained `unregister()` would
    /// kill a live backup (Ruling R68): shown as not running, logged, and decided again at the next
    /// heartbeat, for at most `AgentHealthPolicy.hungResticCap`.
    case waitForRunningRestic
    /// The agent is already draining: "Updating the background agent…", with Back Up Now disabled. The
    /// app asks it to restart once drained, which also frees an agent left drained by an app that quit
    /// half-way through a re-registration.
    case waitForUpdate
    /// "Background agent is switched off", with "Open Login Items". Never re-enabled automatically.
    case showSwitchedOff
    /// "Background agent isn't running" (or isn't working properly), with "Restart agent" when
    /// `canRepair`, and "Open Login Items".
    case showNotRunning(canRepair: Bool)
    /// The app's connection admits no agent, as its own signature can't be trusted: no repair can help, and every
    /// one would stop a healthy agent's backups (Ruling T7-1). "Reinstall Restorey".
    case showSignatureUntrusted
}

public enum AgentHealthPolicy: Sendable, Equatable {
    /// Re-register an `enabled` agent that hasn't answered for `unreachableGrace`, at most once per
    /// `repairInterval`.
    case repairAutomatically
    /// Show "Background agent isn't running" with "Restart agent" and "Open Login Items", and leave the
    /// choice to the user.
    case offerRestart

    /// What an `enabled` but unreachable agent gets. The spec §6.2 check (11 Nov 2026) showed that
    /// switching the agent off in Login Items reads `requiresApproval` and removes the job, so an
    /// `enabled` agent that doesn't answer is a fault and is repaired (Ruling R54).
    public static let enabledButUnreachable: AgentHealthPolicy = .repairAutomatically

    /// How long an `enabled` agent must stay unreachable before an automatic repair. `unregister()`
    /// kills a running restic, so one missed heartbeat (a busy or briefly stopped agent) must not
    /// trigger it: three heartbeats.
    public static let unreachableGrace: TimeInterval = 30

    /// How long an `enabled` agent that doesn't answer is waited on while a restic it started runs, measured from
    /// `unreachableAwakeFor` like the grace (owner, 20 Nov 2026). A backup that runs on past it is taken as hung: the
    /// re-registration goes ahead, stopping it, and the menu says so.
    public static let hungResticCap: TimeInterval = 30 * 60

    /// At most one automatic repair of each kind an hour.
    public static let repairInterval: TimeInterval = 3600
    /// `hello` every 10 s.
    public static let heartbeatInterval: TimeInterval = 10
}

/// The current run of failed heartbeats from an `enabled` agent, timed in awake time: the app feeds it
/// `SuspendingClock` readings, which stop while the Mac sleeps and ignore wall-clock changes (fix round 1 of Task 11).
/// A run starts when the first failing hello was asked, so a call that only fails at its timeout doesn't stretch the
/// grace.
public struct UnreachableRun: Sendable, Equatable {
    public private(set) var startedAt: Duration?

    public init() {}

    /// `failing`: an `enabled` agent's hello failed this heartbeat. Returns `AgentHealthInput.unreachableAwakeFor`.
    public mutating func heartbeat(failing: Bool, askedAt: Duration, now: Duration) -> TimeInterval? {
        guard failing else {
            startedAt = nil
            return nil
        }
        let start = startedAt ?? askedAt
        startedAt = start
        let elapsed = (now - start).components
        return max(0, TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18)
    }
}

/// What a failed `register()` shows. While the connection admits no agent the cause the user can act on is the
/// signature, since no registration would let the app talk to the agent; the registration error is only logged
/// (fix round 1 of Task 11, controller ruling).
public func healthAfterFailedRegistration(_ sentence: String, connectionRefusesEveryAgent: Bool) -> AgentHealthState {
    connectionRefusesEveryAgent ? .signatureUntrusted : .failed(sentence)
}

/// The repair table (spec §6.2 and §8, spike H3a, H6 and phase B).
public func decideAgentHealth(
    _ input: AgentHealthInput, enabledButUnreachable: AgentHealthPolicy = AgentHealthPolicy.enabledButUnreachable
) -> AgentHealthAction {
    /// Every automatic repair restarts the agent, so a fault that survives one waits for the user.
    func repair(_ action: AgentHealthAction) -> AgentHealthAction {
        let kind: RepairKind = action == .restartAfterDrain ? .restart : .reregister
        return input.repairAttemptedRecently(kind) ? .showNotRunning(canRepair: true) : action
    }

    switch input.smStatus {
    case .notFound, .notRegistered:
        return .register
    case .requiresApproval:
        return .showSwitchedOff
    case .enabled:
        // Every hello fails whatever the agent's state, so nothing here can be decided from it, and every repair would
        // stop a healthy agent's backups.
        if input.connectionRefusesEveryAgent { return .showSignatureUntrusted }
        guard case .ok(let reply) = input.heartbeat else {
            switch enabledButUnreachable {
            case .repairAutomatically:
                let unreachableFor = input.unreachableAwakeFor ?? 0
                guard unreachableFor >= AgentHealthPolicy.unreachableGrace else {
                    return .showNotRunning(canRepair: true)
                }
                // An unreachable agent can't be drained, so the re-registration would kill the restic: waited on,
                // but not for ever.
                if input.resticRunningUnderAgent {
                    guard unreachableFor >= AgentHealthPolicy.hungResticCap else { return .waitForRunningRestic }
                    return repair(.reregisterStoppingBackup)
                }
                return repair(.reregisterAfterDrain)
            case .offerRestart: return .showNotRunning(canRepair: true)
            }
        }
        // A re-pointed registration is never restarted: launchd would start the copy elsewhere again.
        if !isInside(reply.executablePath, prefix: input.expectedExecutablePrefix) {
            return repair(.reregisterAfterDrain)
        }
        if reply.draining { return .waitForUpdate }
        // Before any plist re-registration: a stale agent may not know `prepareForReregistration`, but
        // every agent has `prepareForRestart`. The fresh agent is then re-registered on a later heartbeat.
        if !agentIsCurrent(
            reply, appVersion: input.appVersion, appBuild: input.appBuild,
            executableFingerprintOnDisk: input.executableFingerprintOnDisk) {
            return repair(.restartAfterDrain)
        }
        if plistNeedsReregistration(stored: input.storedPlistHash, current: input.currentPlistHash) {
            return repair(.reregisterAfterDrain)
        }
        return .none
    }
}

/// Case-insensitive, as APFS is by default, and on whole path components.
private func isInside(_ path: String, prefix: String) -> Bool {
    let directory = prefix.hasSuffix("/") ? prefix : prefix + "/"
    let standardised = URL(fileURLWithPath: path).standardizedFileURL.path
    return standardised.lowercased().hasPrefix(directory.lowercased())
}

/// The agent runs this app's version and build, from the binary now on disk. An agent that kept running
/// a replaced binary (a fingerprint that differs, or none from an agent older than fingerprints) is not
/// current, even with the same version and build.
public func agentIsCurrent(
    _ reply: HelloReply, appVersion: String, appBuild: String, executableFingerprintOnDisk: String?
) -> Bool {
    guard reply.agentVersion == appVersion, reply.agentBuild == appBuild else { return false }
    guard let running = reply.executableFingerprint, let disk = executableFingerprintOnDisk else { return false }
    return running == disk
}

/// Spec §8: re-register when the embedded plist differs from the one recorded at the last registration.
/// With nothing recorded (registered by an older build, or the app's defaults were reset) launchd's job
/// definition is unknown. It is re-registered once rather than trusted: a stale definition (an old
/// `ProcessType`, a missing Mach service) would otherwise persist silently, and the cost is one drain.
public func plistNeedsReregistration(stored: String?, current: String) -> Bool {
    stored != current
}
