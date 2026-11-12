import Foundation

/// What the agent's Full Disk Access probe found.
public enum FDAProbeResult: Sendable, Equatable {
    case granted
    case missing
    /// None of the protected folders exists, or listing failed for some other reason.
    case cannotVerify
}

/// Decides from the agent's own context whether Full Disk Access is granted (spec §5.7). Without it
/// restic exits 3 with a snapshot of empty folders, which must never look like an ordinary "some files
/// skipped" warning, so the runner probes before every backup.
///
/// The probe lists the first of `protectedDirectories` that exists in `home`. It only reads the
/// folder's entries, never a file's contents.
public enum FullDiskAccessProbe {
    /// Relative to the home folder, tried in this order. TCC protects each one.
    public static let protectedDirectories = ["Library/Safari", "Library/Mail", "Library/Messages"]

    public static func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FDAProbeResult {
        let fm = FileManager.default
        for name in protectedDirectories {
            let path = home.appendingPathComponent(name, isDirectory: true).path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else { return .cannotVerify }
            do {
                _ = try fm.contentsOfDirectory(atPath: path)
                return .granted
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                // NSCocoaError 257: TCC refused the listing (EPERM), as it does without the grant.
                return .missing
            } catch {
                return .cannotVerify
            }
        }
        return .cannotVerify
    }
}
