import CoreServices
import Darwin
import Foundation

/// The real `MarkedItemsFinding`, shared by the agent (before each backup) and the app (the What tab's sheet).
///
/// Spotlight through `MDQueryCreate` and a synchronous `MDQueryExecute` (`kMDQuerySynchronous`, Metadata.framework
/// `MDQuery.h`): it "will not return until the query has finished gathering the initial results", running the calling
/// thread's run loop itself, so it needs no run loop of the caller's, which suits the agent (a LaunchAgent with no UI
/// run loop) and a background thread in the app. `NSMetadataQuery` was not chosen: it delivers results by notification
/// on a run loop someone must keep running, and stopping it is tied to that thread. `MDQuerySetSearchScope` gives
/// `mdfind -onlyin` semantics and `MDQuerySetMaxCount` the bound. The call blocks, so callers run it on their own thread
/// (`MarkedItemsScan.offPool`).
///
/// The attribute is checked with `getxattr(2)` and `XATTR_NOFOLLOW`: metadata only, no symlink followed, no file opened.
public struct SpotlightMarkedItems: MarkedItemsFinding {
    public init() {}

    /// Process-wide: every look at Spotlight in this process shares it, so a hung `mds` blocks one thread at most.
    public var gate: MarkedItemsLookGate { .spotlight }

    public func query(scopes: [String], limit: Int) -> MarkedItemsQuery {
        // A scope that isn't a folder fails the whole query (`MDQueryExecute` returns false), and holds nothing anyway.
        let folders = scopes.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !folders.isEmpty else { return .found([]) }
        guard let query = MDQueryCreate(kCFAllocatorDefault, MarkedNotForBackup.spotlightQuery as CFString, nil, nil) else {
            return .failed
        }
        MDQuerySetSearchScope(query, folders as CFArray, 0)
        MDQuerySetMaxCount(query, limit + 1)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return .failed }
        // No MDQueryDisableUpdates: the result list changes only with kMDQueryWantsUpdates, which isn't passed (and
        // "is ignored if the synchronous parameter is true", MDQuery.h), so it is fixed once MDQueryExecute returns.
        var paths: [String] = []
        let count = MDQueryGetResultCount(query)
        paths.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return .found(paths)
    }

    public func isMarked(_ path: String) -> Bool {
        getxattr(path, MarkedNotForBackup.attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
