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

/// The last automatic repair, persisted in the app's `UserDefaults` so the hourly limit survives a
/// relaunch. A record from another app version or build doesn't count, so a new build restarts the agent
/// at once.
public struct RepairRecord: Codable, Sendable, Equatable {
    public var at: Date
    public var appVersion: String
    public var appBuild: String

    public init(at: Date, appVersion: String, appBuild: String) {
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
    public var lastRepair: RepairRecord?
    public var now: Date

    public init(
        smStatus: AgentServiceStatus, heartbeat: AgentHeartbeat, expectedExecutablePrefix: String,
        appVersion: String, appBuild: String, storedPlistHash: String?, currentPlistHash: String,
        lastRepair: RepairRecord?, now: Date
    ) {
        self.smStatus = smStatus
        self.heartbeat = heartbeat
        self.expectedExecutablePrefix = expectedExecutablePrefix
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.storedPlistHash = storedPlistHash
        self.currentPlistHash = currentPlistHash
        self.lastRepair = lastRepair
        self.now = now
    }

    /// An automatic repair (re-register or restart) by this build ran within the last hour.
    public var repairAttemptedRecently: Bool {
        lastRepair?.isRecent(appVersion: appVersion, appBuild: appBuild, now: now) ?? false
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

    /// At most one automatic repair an hour.
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
        input.repairAttemptedRecently ? .showNotRunning(canRepair: true) : action
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
        if !isInside(reply.executablePath, prefix: input.expectedExecutablePrefix)
            || input.storedPlistHash != input.currentPlistHash {
            return repair(.reregisterAfterDrain)
        }
        if reply.draining { return .waitForUpdate }
        if reply.agentBuild != input.appBuild || reply.agentVersion != input.appVersion {
            return repair(.restartAfterDrain)
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
