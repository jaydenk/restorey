import Foundation

public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    /// Nil when the charge cannot be read. An unknown percentage on battery with `.minimumPercent` runs
    /// rather than skips: skipping on a permanently unreadable reading would stop backups silently.
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
/// `.noNetwork`. The network checks apply only to a repository that needs the network
/// (`Repository.needsNetwork`); `skipOnConstrainedNetwork` is the plan's toggle for the constrained one.
///
/// Every source on `/Volumes/<name>` (the path itself or anything below it) requires `/Volumes/<name>`
/// to be a mount point, whether or not the path exists. When the drive is unplugged, macOS can leave
/// a stale directory at `/Volumes/<name>` (or something can recreate one), so the path may exist
/// while the drive does not; backing up then would make restic back up the wrong tree and fork the
/// snapshot group. An unmounted volume is therefore always a skip, checked across every source before
/// any other missing source is reported (the drive's absence explains the rest). Only after all volume
/// checks pass does a missing source fail.
public func preflight(plan: Plan, env: PreflightEnvironment) -> PreflightResult {
    // Only a repository on another machine needs the network (Ruling R69): a plan backing up to a
    // folder or an external drive runs offline and on any network.
    if plan.repository.needsNetwork {
        switch env.network {
        case .unsatisfied:
            return .skip(.noNetwork)
        case .satisfied(let constrained, let expensive):
            if plan.conditions.skipOnConstrainedNetwork && (constrained || expensive) {
                return .skip(.constrainedNetwork)
            }
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

    for source in plan.sources {
        if let volume = volumeName(of: source), !env.isMountPoint("/Volumes/\(volume)") {
            return .skip(.volumeNotMounted(volume))
        }
    }
    if let missing = plan.sources.first(where: { !env.fileExists($0) }) {
        return .fail("\(missing) doesn't exist")
    }
    return .run
}

/// `Backup` for `/Volumes/Backup` and `/Volumes/Backup/Photos`; nil for anything else.
private func volumeName(of path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2, components[0] == "Volumes" else { return nil }
    return String(components[1])
}
