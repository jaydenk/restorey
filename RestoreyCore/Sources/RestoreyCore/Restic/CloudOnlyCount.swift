import Foundation

/// How many cloud-only files (iCloud Drive or other File Provider storage, "Optimise Mac Storage") a backup skipped
/// because of `--exclude-cloud-files`. restic 0.19.1 reports no count for them, so Restorey counts them itself
/// (`CloudOnlyCounter`) over the File Provider folders the plan's sources reach. It is information only: it never
/// changes a run's outcome, the icon, alerts or check-in pings. An approximation: restic's own exclusion patterns
/// aren't applied (see `CloudOnlyScope.literalPath`).
public struct CloudOnlyCount: Codable, Sendable, Equatable {
    /// Files and folders that exist only in the cloud. A cloud-only folder counts as one, and is never listed.
    public var skipped: Int
    /// True when any of them were under `~/Library/CloudStorage` rather than `~/Library/Mobile Documents`,
    /// so the wording says "cloud files" rather than "iCloud files".
    public var includesOtherProviders: Bool

    public init(skipped: Int, includesOtherProviders: Bool) {
        self.skipped = skipped
        self.includesOtherProviders = includesOtherProviders
    }
}

/// One folder to walk, and where it sits.
public struct CloudOnlyRoot: Sendable, Equatable {
    public var path: String
    /// Under `~/Library/CloudStorage` (third-party providers) rather than iCloud Drive.
    public var isOtherProvider: Bool

    public init(path: String, isOtherProvider: Bool) {
        self.path = path
        self.isOtherProvider = isOtherProvider
    }
}

/// What the walker found at one place. Read from `lstat` alone: nothing is opened and no symlink followed.
public struct CloudOnlyEntry: Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// `SF_DATALESS` is set: the content is in the cloud, not on this Mac.
    public var isDataless: Bool

    public init(path: String, isDirectory: Bool, isSymlink: Bool = false, isDataless: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isDataless = isDataless
    }
}

public enum CloudOnlyAction: Sendable, Equatable {
    /// Carry on, listing a directory's children.
    case descend
    /// Don't list this directory (listing a cloud-only folder makes macOS fetch it).
    case skipChildren
    /// Stop the whole walk.
    case stop
}

/// Walks a folder tree reading metadata only, calling `visit` for each entry, parents before children.
public protocol CloudOnlyWalking: Sendable {
    func walk(root: String, visit: (CloudOnlyEntry) -> CloudOnlyAction)
}

/// Which folders to walk: the File Provider roots, narrowed to what the plan's sources reach.
public enum CloudOnlyScope {
    static let iCloudRoot = "Library/Mobile Documents"
    static let otherProvidersRoot = "Library/CloudStorage"

    /// The folders to walk for `sources`, with no folder inside another:
    /// - a source that is a File Provider root, or holds one (the home folder): that root;
    /// - a source inside a root: that source;
    /// - any other source: nothing.
    /// A folder that is, or sits under, one of `exclusions` (literal paths) is left out.
    public static func roots(home: String, sources: [String], exclusions: [String]) -> [CloudOnlyRoot] {
        let home = normalised(home)
        let providers: [(path: String, other: Bool)] = [
            ("\(home)/\(iCloudRoot)", false), ("\(home)/\(otherProvidersRoot)", true),
        ]
        let excluded = Set(exclusions.compactMap(literalPath))
        var found: [CloudOnlyRoot] = []
        for source in sources.map(normalised) {
            for provider in providers {
                let path: String
                if source == provider.path || provider.path.hasPrefix(source + "/") {
                    path = provider.path
                } else if source.hasPrefix(provider.path + "/") {
                    path = source
                } else {
                    continue
                }
                found.append(CloudOnlyRoot(path: path, isOtherProvider: provider.other))
            }
        }
        // One entry per path, then none inside another, so no file is counted twice.
        var seen = Set<String>()
        let distinct = found.filter { seen.insert($0.path).inserted }
        return distinct.filter { root in
            !isExcluded(root.path, by: excluded)
                && !distinct.contains { root.path.hasPrefix($0.path + "/") }
        }
    }

    /// True when `path` is one of `excluded` or sits under one.
    static func isExcluded(_ path: String, by excluded: Set<String>) -> Bool {
        var current = path
        while true {
            if excluded.contains(current) { return true }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return false }
            current = String(current[..<slash])
        }
    }

    /// The path an exclusion names when it is a literal absolute path (backslash escapes undone, as
    /// `DefaultExclusions` writes the home folder), or nil for a glob or a relative pattern. The count is an
    /// approximation and says nothing about restic's pattern semantics, so globs are ignored.
    static func literalPath(_ pattern: String) -> String? {
        guard pattern.hasPrefix("/") else { return nil }
        var result = ""
        var escaped = false
        for character in pattern {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if "*?[".contains(character) {
                return nil
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : normalised(result)
    }

    static func normalised(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Counts cloud-only entries under the plan's File Provider roots, within a bound.
public struct CloudOnlyCounter: Sendable {
    /// Visited entries after which the count is given up.
    public static let defaultEntryLimit = 1_000_000
    /// Seconds after which the count is given up.
    public static let defaultTimeLimit: TimeInterval = 10

    public var walker: any CloudOnlyWalking
    public var entryLimit: Int
    /// True once the time limit has passed; asked every few hundred entries.
    public var isOutOfTime: @Sendable () -> Bool

    public init(
        walker: any CloudOnlyWalking, entryLimit: Int = CloudOnlyCounter.defaultEntryLimit,
        timeLimit: TimeInterval = CloudOnlyCounter.defaultTimeLimit
    ) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeLimit))
        self.init(walker: walker, entryLimit: entryLimit, isOutOfTime: { ContinuousClock.now >= deadline })
    }

    public init(walker: any CloudOnlyWalking, entryLimit: Int, isOutOfTime: @escaping @Sendable () -> Bool) {
        self.walker = walker
        self.entryLimit = entryLimit
        self.isOutOfTime = isOutOfTime
    }

    public enum Result: Sendable, Equatable {
        case counted(CloudOnlyCount)
        /// The bound was reached: nothing is recorded.
        case gaveUp
    }

    /// Nothing to walk is a count of 0, not a give-up.
    public func count(roots: [CloudOnlyRoot], exclusions: [String]) -> Result {
        let excluded = Set(exclusions.compactMap(CloudOnlyScope.literalPath))
        var skipped = 0
        var other = false
        var visited = 0
        var gaveUp = false
        for root in roots {
            walker.walk(root: root.path) { entry in
                visited += 1
                if visited > entryLimit || (visited % 256 == 0 && isOutOfTime()) {
                    gaveUp = true
                    return .stop
                }
                if entry.isSymlink { return .skipChildren }
                if entry.isDataless {
                    skipped += 1
                    if root.isOtherProvider { other = true }
                    return .skipChildren
                }
                if entry.isDirectory, excluded.contains(CloudOnlyScope.normalised(entry.path)) { return .skipChildren }
                return .descend
            }
            if gaveUp { return .gaveUp }
        }
        return .counted(CloudOnlyCount(skipped: skipped, includesOtherProviders: other))
    }
}

/// The words for the count, in the History row and the Overview.
public enum CloudOnlyText {
    /// "4,834 iCloud files not on this Mac skipped" (History), or "cloud files" when any came from another provider.
    /// Nil for nil and 0.
    public static func summary(_ count: CloudOnlyCount?, locale: Locale) -> String? {
        phrase(count, locale: locale).map { "\($0.number) \($0.noun) not on this Mac skipped" }
    }

    /// "4,834 iCloud files not on this Mac were skipped." (Overview; "1 iCloud file … was skipped.")
    public static func sentence(_ count: CloudOnlyCount?, locale: Locale) -> String? {
        phrase(count, locale: locale).map {
            "\($0.number) \($0.noun) not on this Mac \($0.plural ? "were" : "was") skipped."
        }
    }

    /// What to do about it, shown under `sentence`.
    public static let howTo =
        "To include them, download them in Finder (Download Now) or turn off Optimise Mac Storage."

    private static func phrase(_ count: CloudOnlyCount?, locale: Locale) -> (number: String, noun: String, plural: Bool)? {
        guard let count, count.skipped > 0 else { return nil }
        let plural = count.skipped != 1
        let kind = count.includesOtherProviders ? "cloud" : "iCloud"
        return (count.skipped.formatted(.number.locale(locale)), "\(kind) \(plural ? "files" : "file")", plural)
    }
}
