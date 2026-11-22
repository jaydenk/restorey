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

/// The kind of link a satisfied network path uses. Wi-Fi wins over wired when a path offers both.
public enum NetworkInterface: String, Sendable, Equatable {
    case wiFi, wired, other
}

public enum NetworkState: Sendable, Equatable {
    case unsatisfied
    case satisfied(constrained: Bool, expensive: Bool, interface: NetworkInterface = .other)
}

/// Which network the Mac is on, for the per-network upload speed; nil when there is no network. A Wi-Fi
/// link whose name is unreadable (no Location permission, or no name) is `.wiFiUnknown`.
public func networkKey(for state: NetworkState, wiFiName: String?) -> NetworkKey? {
    guard case .satisfied(_, _, let interface) = state else { return nil }
    switch interface {
    case .wiFi:
        let name = wiFiName.map(NetworkSettings.trimmed) ?? ""
        return name.isEmpty ? .wiFiUnknown : .wiFi(name: name)
    case .wired: return .ethernet
    case .other: return .other
    }
}

/// Everything `preflight` knows about the machine, injected so the decision stays pure and the tests
/// never touch real power, network or filesystem state.
public struct PreflightEnvironment: Sendable {
    public var power: PowerState
    public var network: NetworkState
    /// Whether the path is the root of a mounted volume.
    public var isMountPoint: @Sendable (String) -> Bool
    public var fileExists: @Sendable (String) -> Bool
    /// The Mac-wide network rules (`ConfigFile.network`). The plan runner sets them from the config.
    public var networkSettings: NetworkSettings
    /// The Wi-Fi network's name, or nil when it can't be read (no Location permission, or not on Wi-Fi),
    /// which never skips (Ruling P2-8). Called only when the skip list has names, and by the plan runner on Wi-Fi
    /// when the Mac-wide limit is a percentage (`PlanRunner.currentNetwork`).
    public var currentWiFiName: @Sendable () -> String?

    public init(
        power: PowerState,
        network: NetworkState,
        isMountPoint: @escaping @Sendable (String) -> Bool,
        fileExists: @escaping @Sendable (String) -> Bool,
        networkSettings: NetworkSettings = .defaults,
        currentWiFiName: @escaping @Sendable () -> String? = { nil }
    ) {
        self.power = power
        self.network = network
        self.isMountPoint = isMountPoint
        self.fileExists = fileExists
        self.networkSettings = networkSettings
        self.currentWiFiName = currentWiFiName
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
/// (`Repository.needsNetwork`), in this order: no network, a constrained or expensive network (when the
/// Mac-wide `skipOnConstrainedNetwork` is on), then a Wi-Fi network in the Mac-wide skip list, matched
/// ignoring case (`NetworkSettings.isSkipped(wiFiName:)`). The rules come from `env.networkSettings`.
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
        case .satisfied(let constrained, let expensive, _):
            if env.networkSettings.skipOnConstrainedNetwork && (constrained || expensive) {
                return .skip(.constrainedNetwork)
            }
            if !env.networkSettings.skippedWiFiNames.isEmpty, let name = env.currentWiFiName(),
                env.networkSettings.isSkipped(wiFiName: name)
            {
                return .skip(.skippedWiFi(name))
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
        return .fail("\(missing) doesn’t exist")
    }
    return .run
}

/// `Backup` for `/Volumes/Backup` and `/Volumes/Backup/Photos`; nil for anything else.
private func volumeName(of path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2, components[0] == "Volumes" else { return nil }
    return String(components[1])
}
