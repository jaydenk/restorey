import Foundation

public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    /// Nil when the charge cannot be read.
    public var percent: Int?

    public init(onBattery: Bool, percent: Int?) {
        self.onBattery = onBattery
        self.percent = percent
    }
}

public enum NetworkState: Sendable, Equatable {
    case unsatisfied
    case satisfied(constrained: Bool, expensive: Bool)
}

/// Everything `preflight` knows about the machine, injected so the decision stays pure and the tests
/// never touch real power, network or filesystem state.
public struct PreflightEnvironment: Sendable {
    public var power: PowerState
    public var network: NetworkState
    /// Whether the path is the root of a mounted volume.
    public var isMountPoint: @Sendable (String) -> Bool
    public var fileExists: @Sendable (String) -> Bool

    public init(
        power: PowerState,
        network: NetworkState,
        isMountPoint: @escaping @Sendable (String) -> Bool,
        fileExists: @escaping @Sendable (String) -> Bool
    ) {
        self.power = power
        self.network = network
        self.isMountPoint = isMountPoint
        self.fileExists = fileExists
    }
}

public enum PreflightResult: Equatable, Sendable {
    case run
    case skip(SkipReason)
    /// A configuration problem, not a transient condition. The message is shown to the user.
    case fail(String)
}

/// Decides whether a due run should start. The checks run in a fixed order and the first that trips
/// wins: network, then battery, then volumes and sources. So no network on a low battery is
/// `.noNetwork`.
///
/// A source that is missing because its external volume is not mounted is a skip, never a failure
/// and never a backup: backing up with the drive unplugged would write a snapshot without that
/// source's files and fork the snapshot group. It is checked across every source before any other
/// missing source is reported, because the drive's absence explains the rest. A source on `/Volumes`
/// counts as unmounted when it is missing and `/Volumes/<name>` is not a mount point.
public func preflight(plan: Plan, env: PreflightEnvironment) -> PreflightResult {
    switch env.network {
    case .unsatisfied:
        return .skip(.noNetwork)
    case .satisfied(let constrained, let expensive):
        if plan.conditions.skipOnConstrainedNetwork && (constrained || expensive) {
            return .skip(.constrainedNetwork)
        }
    }

    if env.power.onBattery {
        switch plan.conditions.battery {
        case .neverOnBattery:
            return .skip(.onBattery)
        case .minimumPercent(let minimum):
            if let percent = env.power.percent, percent < minimum { return .skip(.batteryBelow(minimum)) }
        }
    }

    let missing = plan.sources.filter { !env.fileExists($0) }
    for source in missing {
        if let volume = volumeName(of: source), !env.isMountPoint("/Volumes/\(volume)") {
            return .skip(.volumeNotMounted(volume))
        }
    }
    if let first = missing.first { return .fail("\(first) doesn't exist") }
    return .run
}

/// `Backup` for `/Volumes/Backup` and `/Volumes/Backup/Photos`; nil for anything else.
private func volumeName(of path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2, components[0] == "Volumes" else { return nil }
    return String(components[1])
}
