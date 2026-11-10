import Darwin
import Foundation
import RestoreyCore

// Stand-ins the plan runner needs until the v0.1 engine's later steps replace them: the scheduler's
// system observers (power, network, mounts) and the check-in service. Until then only "Back up now"
// starts a backup, and the README says that conditions and check-in pings aren't live yet.

/// Logs each ping instead of sending it. The check-in service replaces this.
struct InterimCheckInSender: CheckInSending {
    let log: AppLog

    func send(_ ping: CheckInPing, planID: UUID) async {
        let name =
            switch ping {
            case .start: "start"
            case .success: "success"
            case .fail: "fail"
            }
        log.info("Check-in \(name) ping for plan \(planID.uuidString) not sent: this build doesn't send check-in pings yet")
    }
}

/// The machine as the runner's pre-run checks see it until the system observers exist: power and
/// network are reported as fine, and mounts and files are read from the file system.
enum InterimPreflight {
    static func environment() -> PreflightEnvironment {
        PreflightEnvironment(
            power: PowerState(onBattery: false, percent: nil),
            network: .satisfied(constrained: false, expensive: false),
            isMountPoint: isMountPoint,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// True when `path` (symlinks resolved, so the boot volume's /Volumes link counts) is where a
    /// file system is mounted.
    static func isMountPoint(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = statfs()
        guard statfs(resolved, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mountedOn == resolved
    }
}
