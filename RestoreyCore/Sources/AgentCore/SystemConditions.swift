import Darwin
import Foundation
import IOKit.ps
import RestoreyCore

/// The machine readings behind `preflight` that need no long-lived observer: whether a path is a mount
/// point, and the power state. The agent's `SystemObservers` combines them with the network.
public enum SystemConditions {
    /// True when `path`, with every symlink resolved, is where a file system is mounted. Resolving first
    /// matters for the boot volume: `/Volumes/Macintosh HD` is a symlink to `/`. A missing path, or one
    /// that can't be resolved, is not a mount point.
    public static func isMountPoint(_ path: String) -> Bool {
        guard !path.isEmpty, let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        var info = statfs()
        guard statfs(resolved, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mountedOn == String(cString: resolved)
    }

    /// The power state now, from IOKit's power sources.
    public static func currentPowerState() -> PowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(onBattery: false, percent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let sources = list.compactMap { source in
            IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        }
        return powerState(providingType: providing, sources: sources)
    }

    /// The power state from `IOPSGetProvidingPowerSourceType` and the power sources' descriptions.
    /// On battery means the providing source is the battery (a UPS doesn't count: that is a desktop
    /// on mains backup). The charge is the first present internal battery's current capacity over its
    /// maximum, as a whole percentage. A Mac with no battery is `onBattery: false, percent: nil`.
    static func powerState(providingType: String?, sources: [[String: Any]]) -> PowerState {
        let onBattery = providingType == kIOPSBatteryPowerValue
        let battery = sources.first { source in
            source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && source[kIOPSIsPresentKey] as? Bool != false
        }
        var percent: Int?
        if let battery, let current = battery[kIOPSCurrentCapacityKey] as? Int,
            let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0
        {
            percent = min(100, max(0, Int((Double(current) * 100 / Double(maximum)).rounded())))
        }
        return PowerState(onBattery: onBattery, percent: percent)
    }
}
