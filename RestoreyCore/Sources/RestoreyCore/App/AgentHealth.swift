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
    public var now: Date

    public init(
        smStatus: AgentServiceStatus, heartbeat: AgentHeartbeat, expectedExecutablePrefix: String,
        appVersion: String, appBuild: String, storedPlistHash: String?, currentPlistHash: String,
        executableFingerprintOnDisk: String?, lastRepairs: [RepairRecord], now: Date
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
    /// `prepareForRestart`; launchd's `KeepAlive` starts the new binary.
    case restartAfterDrain
    /// The agent is already draining: "Updating the background agent…", with Back Up Now disabled. The
    /// app asks it to restart once drained, which also frees an agent left drained by an app that quit
    /// half-way through a re-registration.
    case waitForUpdate
    /// "Background agent is switched off", with "Open Login Items". Never re-enabled automatically.
    case showSwitchedOff
    /// "Background agent isn't running" (or isn't working properly), with "Restart agent" when
    /// `canRepair`, and "Open Login Items".
    case showNotRunning(canRepair: Bool)
}

public enum AgentHealthPolicy: Sendable, Equatable {
    /// Re-register an `enabled` agent that doesn't answer, at most once per `repairInterval`.
    case repairAutomatically
    /// Show "Background agent isn't running" with "Restart agent" and "Open Login Items", and leave the
    /// choice to the user.
    case offerRestart

    /// What an `enabled` but unreachable agent gets. Ruling R50: `.offerRestart` until the spec §6.2
    /// check shows whether "switched off in Login Items" reads `requiresApproval` (then it can be
    /// `.repairAutomatically`) or `enabled` (then it must stay as it is, or the app would re-enable an
    /// agent the user switched off).
    public static let enabledButUnreachable: AgentHealthPolicy = .offerRestart

    /// At most one automatic repair of each kind an hour.
    public static let repairInterval: TimeInterval = 3600
    /// `hello` every 10 s.
    public static let heartbeatInterval: TimeInterval = 10
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
        guard case .ok(let reply) = input.heartbeat else {
            switch enabledButUnreachable {
            case .repairAutomatically: return repair(.reregisterAfterDrain)
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
