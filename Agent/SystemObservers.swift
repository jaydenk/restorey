import AgentCore
import AppKit
import Foundation
import IOKit.pwr_mgt
import Network
import RestoreyCore

/// The machine as the agent sees it: the network path (a long-lived `NWPathMonitor`), the power state
/// and mount points (read on demand), wake and mount notifications, and the idle-sleep assertion held
/// while restic runs (spec §5.5, §8).
final class SystemObservers: Sendable {
    private let monitor = NWPathMonitor()
    private let network = NetworkPath()

    /// `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)`: idle sleep only, so the
    /// display still sleeps.
    static let sleepAssertions = SleepPrevention.AssertionAPI(
        create: { name in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString, &id)
            return result == kIOReturnSuccess ? id : nil
        },
        release: { id in _ = IOPMAssertionRelease(id) })

    /// Starts watching the network path.
    init() {
        monitor.pathUpdateHandler = { [network] path in
            network.update(
                path.status == .satisfied
                    ? .satisfied(constrained: path.isConstrained, expensive: path.isExpensive) : .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "com.jaydenkerr.restorey.agent.network"))
    }

    deinit { monitor.cancel() }

    /// What `preflight` checks before each run.
    func preflightEnvironment() -> PreflightEnvironment {
        PreflightEnvironment(
            power: SystemConditions.currentPowerState(),
            network: network.forPreflight,
            isMountPoint: { SystemConditions.isMountPoint($0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Returns once the network path is satisfied, at once if it already is, or when cancelled.
    func waitForNetwork() async {
        await network.waitUntilSatisfied()
    }
}

/// Wake and mount notifications from `NSWorkspace`, which posts them on the main thread.
@MainActor
final class WorkspaceObserver {
    private var tokens: [any NSObjectProtocol] = []

    /// - Parameters:
    ///   - onWake: called after the Mac wakes from sleep.
    ///   - onMount: called with the mount path of each volume mounted (`/Volumes/<name>`).
    func start(onWake: @escaping @Sendable () -> Void, onMount: @escaping @Sendable (String) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            onWake()
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            onMount(url.path)
        })
    }
}
