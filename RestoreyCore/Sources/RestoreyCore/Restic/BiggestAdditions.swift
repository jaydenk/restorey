import Foundation
import Synchronization

/// What a backup added to the repository, biggest first (Task 16d): the files whose new data took the most space after
/// compression and encryption (`data_size_in_repo`), and the folders whose files together did, so a library made of
/// many small changed files shows up too. Kept on the backup's `RunRecord` so the next exclusion rests on evidence.
/// From Task 16f it also counts restic's folder listings (each new or changed folder's own tree), which on a home folder
/// are about half of what a backup adds. Information only: no outcome, icon, alert or ping depends on it.
public struct BiggestAdditions: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var bytesAdded: Int64

        public init(path: String, bytesAdded: Int64) {
            self.path = path
            self.bytesAdded = bytesAdded
        }
    }

    /// The most files and folders a record keeps.
    public static let fileLimit = 10
    public static let folderLimit = 5

    /// At most `fileLimit`, biggest first, equal sizes by path.
    public var files: [Entry]
    /// At most `folderLimit`, biggest first, equal sizes by path (`BiggestAdditionsCollector.folderKey`). A folder's size
    /// is its files' data and, from Task 16f, the listings of the folders it groups.
    public var folders: [Entry]
    /// Every file's `data_size_in_repo` added up: what the files added, folders' own trees left out.
    public var totalBytesAdded: Int64
    /// Every new or modified folder's `metadata_size_in_repo` added up (Task 16f): what restic's folder listings added,
    /// including the folders above the sources. Nil for a record written before Task 16f; omitted from JSON while nil.
    public var listingsBytesAdded: Int64?
    /// The backup touched more folders than the collector keeps count of (`folderKeyLimit`), so folders first seen
    /// after that weren't counted. Omitted from JSON while false.
    public var foldersIncomplete: Bool

    public init(
        files: [Entry], folders: [Entry], totalBytesAdded: Int64, listingsBytesAdded: Int64? = nil,
        foldersIncomplete: Bool = false
    ) {
        self.files = files
        self.folders = folders
        self.totalBytesAdded = totalBytesAdded
        self.listingsBytesAdded = listingsBytesAdded
        self.foldersIncomplete = foldersIncomplete
    }

    private enum CodingKeys: String, CodingKey { case files, folders, totalBytesAdded, listingsBytesAdded, foldersIncomplete }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Kept to this build's caps, so a record a newer build wrote can't grow what the sheet shows.
        files = Array((try c.decodeIfPresent([Entry].self, forKey: .files) ?? []).prefix(Self.fileLimit))
        folders = Array((try c.decodeIfPresent([Entry].self, forKey: .folders) ?? []).prefix(Self.folderLimit))
        totalBytesAdded = try c.decodeIfPresent(Int64.self, forKey: .totalBytesAdded) ?? files.reduce(0) { $0 + $1.bytesAdded }
        listingsBytesAdded = try c.decodeIfPresent(Int64.self, forKey: .listingsBytesAdded)
        foldersIncomplete = try c.decodeIfPresent(Bool.self, forKey: .foldersIncomplete) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(files, forKey: .files)
        try c.encode(folders, forKey: .folders)
        try c.encode(totalBytesAdded, forKey: .totalBytesAdded)
        try c.encodeIfPresent(listingsBytesAdded, forKey: .listingsBytesAdded)
        if foldersIncomplete { try c.encode(true, forKey: .foldersIncomplete) }
    }

    /// Biggest first, then by path, so the lists don't depend on the order restic finished the files in.
    static func precedes(_ a: Entry, _ b: Entry) -> Bool {
        a.bytesAdded != b.bytesAdded ? a.bytesAdded > b.bytesAdded : a.path < b.path
    }
}

/// Collects a backup's biggest additions from restic's verbose lines as they stream past (Task 16d). Memory stays
/// bounded whatever the backup's size: the top `fileLimit` files, two running totals, and one sum per folder for at
/// most `folderKeyLimit` folders. It runs on the drain thread for every new or changed file and folder, so each line
/// costs a lock, a comparison with the smallest of ten (files only), and one dictionary update. Unchanged items are
/// dropped before they get here (`ResticMessageParser.isUnchangedVerboseLine`), and anything else is ignored.
public final class BiggestAdditionsCollector: Sendable {
    private struct State {
        var sawVerboseLine = false
        /// Sorted by `BiggestAdditions.precedes`, at most `fileLimit`.
        var files: [BiggestAdditions.Entry] = []
        var total: Int64 = 0
        var listings: Int64 = 0
        var folders: [String: Int64] = [:]
        var foldersIncomplete = false
    }

    /// How many folders below a source a file's folder is counted at: `~/Library/Application Support/BeeperTexts`.
    static let folderDepth = 3
    /// How many folders a backup keeps sums for. A home folder's first backup touches far fewer folders this deep.
    public static let defaultFolderKeyLimit = 50_000

    private let roots: [String]
    private let folderKeyLimit: Int
    private let state = Mutex(State())

    /// - Parameter sources: the plan's sources, as restic was given them (its items carry the same paths).
    public init(sources: [String], folderKeyLimit: Int = defaultFolderKeyLimit) {
        roots = Self.roots(sources)
        self.folderKeyLimit = folderKeyLimit
    }

    /// Cheap and non-blocking: safe on the drain thread.
    public func collect(_ message: ResticMessage) {
        guard case .verboseStatus(let item) = message else { return }
        if let item, item.isAddedFile {
            let entry = BiggestAdditions.Entry(path: item.item, bytesAdded: item.dataSizeInRepo)
            let folder = Self.folderKey(item.item, sortedRoots: roots)
            let limit = folderKeyLimit
            state.withLock { state in
                state.sawVerboseLine = true
                state.total = Self.adding(entry.bytesAdded, to: state.total)
                Self.insert(entry, into: &state.files)
                Self.add(entry.bytesAdded, to: folder, in: &state, limit: limit)
            }
        } else if let item, item.isAddedFolder {
            let bytes = item.metadataSizeInRepo
            let folder = Self.folderKey(forFolder: item.item, sortedRoots: roots)
            let limit = folderKeyLimit
            state.withLock { state in
                state.sawVerboseLine = true
                state.listings = Self.adding(bytes, to: state.listings)
                if let folder { Self.add(bytes, to: folder, in: &state, limit: limit) }
            }
        } else {
            state.withLock { $0.sawVerboseLine = true }
        }
    }

    private static func add(_ bytes: Int64, to folder: String, in state: inout State, limit: Int) {
        if let sum = state.folders[folder] {
            state.folders[folder] = adding(bytes, to: sum)
        } else if state.folders.count < limit {
            state.folders[folder] = bytes
        } else {
            state.foldersIncomplete = true
        }
    }

    /// `sum + bytes`, held at `Int64.max` rather than wrapping.
    private static func adding(_ bytes: Int64, to sum: Int64) -> Int64 {
        let (added, overflow) = sum.addingReportingOverflow(bytes)
        return overflow ? .max : added
    }

    /// What was collected; nil when restic printed no verbose line at all (it wasn't asked to, or is a version that
    /// doesn't). A backup that made a snapshot always prints some: the folders that changed, and the scan's end.
    public func result() -> BiggestAdditions? {
        state.withLock { state in
            guard state.sawVerboseLine else { return nil }
            let folders = state.folders.map { BiggestAdditions.Entry(path: $0.key, bytesAdded: $0.value) }
                .sorted(by: BiggestAdditions.precedes)
                .prefix(BiggestAdditions.folderLimit)
            return BiggestAdditions(
                files: state.files, folders: Array(folders), totalBytesAdded: state.total,
                listingsBytesAdded: state.listings, foldersIncomplete: state.foldersIncomplete)
        }
    }

    private static func insert(_ entry: BiggestAdditions.Entry, into files: inout [BiggestAdditions.Entry]) {
        if files.count == BiggestAdditions.fileLimit {
            guard let last = files.last, BiggestAdditions.precedes(entry, last) else { return }
            files.removeLast()
        }
        let index = files.firstIndex { BiggestAdditions.precedes(entry, $0) } ?? files.count
        files.insert(entry, at: index)
    }

    // MARK: Folders

    /// The folder a file's addition counts towards: below the deepest source holding it, up to `folderDepth` folders
    /// down, stopping at a package such as `Photos Library.photoslibrary` (a folder whose name has an extension), so
    /// its many small files add up in one place. A file right inside a source counts towards the source; a source that
    /// is itself a file, towards its folder. A source of "/" counts from the top (`/Users/me/Pictures`).
    static func folderKey(_ path: String, roots: [String]) -> String {
        folderKey(path, sortedRoots: Self.roots(roots))
    }

    private static func folderKey(_ path: String, sortedRoots: [String]) -> String {
        let root = sortedRoots.first { path == $0 || path.hasPrefix(directoryPrefix($0)) } ?? "/"
        if path == root { return parent(of: path) }
        var folders = path.dropFirst(directoryPrefix(root).count).split(separator: "/")
        if !folders.isEmpty { folders.removeLast() } // the file's own name
        var key = root
        for folder in folders.prefix(folderDepth) {
            key = key == "/" ? "/" + folder : key + "/" + folder
            if isPackage(folder) { break }
        }
        return key
    }

    /// The folder a folder's own listing counts towards (Task 16f), by the same rule as a file inside it: itself, or the
    /// folder above it at `folderDepth` or at a package, so a source counts towards itself. Nil for a folder above every
    /// source (`/Users/` when backing up `/Users/me`): restic records those only to reach the sources, so their
    /// listings count in the total but towards no folder. `item` is restic's, ending in "/".
    static func folderKey(forFolder item: String, roots: [String]) -> String? {
        folderKey(forFolder: item, sortedRoots: Self.roots(roots))
    }

    private static func folderKey(forFolder item: String, sortedRoots: [String]) -> String? {
        var path = item
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard sortedRoots.contains(where: { path == $0 || path.hasPrefix(directoryPrefix($0)) }) else { return nil }
        // As for a file inside the folder: the file's name is dropped, so the folder itself is the deepest it can be.
        return folderKey(directoryPrefix(path) + "_", sortedRoots: sortedRoots)
    }

    /// Sources without trailing slashes, deepest first, so the first that holds a path is the closest.
    private static func roots(_ sources: [String]) -> [String] {
        sources.map { source in
            var source = source
            while source.count > 1, source.hasSuffix("/") { source.removeLast() }
            return source
        }
        .sorted { $0.count > $1.count }
    }

    /// What every path inside `directory` starts with: "/" for the root, otherwise the path and a slash.
    private static func directoryPrefix(_ directory: String) -> String {
        directory == "/" ? "/" : directory + "/"
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// A name with an extension; a hidden folder (`.cache`) isn't one.
    private static func isPackage(_ name: Substring) -> Bool {
        name.dropFirst().contains(".")
    }
}
