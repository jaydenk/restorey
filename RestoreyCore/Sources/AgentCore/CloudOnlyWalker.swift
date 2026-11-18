import Darwin
import Foundation
import RestoreyCore

/// Walks a folder with `fts`, reading `lstat` metadata only: no file is opened, no symlink followed (`FTS_PHYSICAL`),
/// no other file system entered (`FTS_XDEV`), and a directory the counter says to skip is never listed
/// (`fts_set(FTS_SKIP)`), because listing a cloud-only folder makes macOS fetch it.
public struct FTSCloudOnlyWalker: CloudOnlyWalking {
    public init() {}

    /// `SF_DATALESS` from `<sys/stat.h>`, set in `st_flags` on an item whose content is in the cloud.
    static let datalessFlag: UInt32 = 0x4000_0000

    public func walk(root: String, visit: (CloudOnlyEntry) -> CloudOnlyAction) {
        let copy = strdup(root)
        defer { free(copy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
        let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
        guard let stream = fts_open(&paths, options, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            // Post-order visits, unreadable and unstat-able entries carry nothing to count.
            guard info == FTS_D || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT else {
                continue
            }
            let isDirectory = info == FTS_D
            let flags = entry.pointee.fts_statp.pointee.st_flags
            let path = String(cString: entry.pointee.fts_path)
            let action = visit(CloudOnlyEntry(
                path: path, isDirectory: isDirectory, isSymlink: info == FTS_SL || info == FTS_SLNONE,
                isDataless: flags & Self.datalessFlag != 0))
            switch action {
            case .descend: break
            case .skipChildren: if isDirectory { fts_set(stream, entry, FTS_SKIP) }
            case .stop: return
            }
        }
    }
}

/// The agent's real counter for `RunnerDependencies.cloudOnlySkipped`.
public enum CloudOnlySkipped {
    /// Walks the File Provider folders under `home` that the plan's sources reach, within the default bound
    /// (10 seconds, 1,000,000 entries). Nil when it gives up.
    public static func counter(home: URL) -> @Sendable ([String], [String]) -> CloudOnlyCounter.Result? {
        { sources, exclusions in
            let roots = CloudOnlyScope.roots(home: home.path, sources: sources, exclusions: exclusions)
            let counter = CloudOnlyCounter(walker: FTSCloudOnlyWalker())
            return counter.count(roots: roots, exclusions: exclusions)
        }
    }
}
