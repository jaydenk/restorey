import Darwin
import Foundation

/// Identifies one copy of the agent binary on disk: device, inode, size and modification time.
///
/// The agent records it for its own executable at launch and reports it in `hello`. The app compares it
/// with the file now at that path. An install replaces the bundle with new files, so an agent that kept
/// running the old binary (launchd doesn't restart it, spike H6) differs even when its version and build
/// are the same, as in every development install (fix round 3).
public enum ExecutableFingerprint {
    /// Nil when the file can't be read.
    public static func of(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let mtime = info.st_mtimespec
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(mtime.tv_sec).\(mtime.tv_nsec)"
    }
}
