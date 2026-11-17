import Foundation
import Synchronization

/// Items apps mark as not for backup (product spec §5.7, Task 15c): Time Machine's per-item exclusion attribute,
/// `com.apple.metadata:com_apple_backup_excludeItem` with the value `com.apple.backupd`, which macOS and apps set on
/// rebuildable, constantly rewritten data (`tmutil addexclusion` writes the same). Time Machine, Arq and Backblaze
/// honour it, and so does Restorey, per plan (`Plan.skipsItemsMarkedNotForBackup`, `Plan.backUpAnyway`).
///
/// restic 0.19.1 knows nothing of the attribute, so before each backup the agent asks Spotlight for the items carrying
/// it within the plan's sources (`MarkedItemsScan`), checks each still has it, collapses the list (`collapse`) and
/// passes it to restic as literal patterns in a file (`excludeFile`, `--exclude-file`). Anything Spotlight can't see
/// (indexing off, a volume not indexed, a folder on Spotlight's privacy list) is simply backed up: the safe direction.
public enum MarkedNotForBackup {
    /// The extended attribute's name, as `getxattr(2)` takes it.
    public static let attributeName = "com.apple.metadata:com_apple_backup_excludeItem"
    /// The Spotlight query for it (`mdfind "com_apple_backup_excludeItem == 'com.apple.backupd'"`, verified read-only on
    /// macOS 27: 1,145 items in a home folder, the same as `=`). Items with another value (`com.apple.MobileBackup`, set
    /// inside simulator devices for iOS backups) are not Time Machine's flag and are left alone.
    public static let spotlightQuery = #"com_apple_backup_excludeItem == "com.apple.backupd""#
    /// Results after which the scan gives up for that run: restic matches every pattern against every path
    /// (`internal/filter/filter.go` `list()`), so a huge list would cost more than it saves.
    public static let resultLimit = 100_000
    /// Seconds after which the scan gives up for that run.
    public static let timeLimit: TimeInterval = 10
    /// The longest line restic can read: `bufio.Scanner`'s 64 KiB token limit, with room to spare. A longer line would
    /// fail the whole backup ("token too long").
    static let maxLineBytes = 60_000

    // MARK: Collapse

    /// The marked items to pass to restic, sorted, with no item inside another. Dropped:
    /// - anything not strictly inside one of `sources` (a source itself, or a folder holding one, is the person's own
    ///   choice and is never skipped whole);
    /// - anything that is, or sits under, a literal path in `exclusions` (globs are ignored: they say nothing exact);
    /// - anything that is, or sits under, an entry in `backUpAnyway`, and anything holding such an entry (excluding it
    ///   would exclude the entry);
    /// - duplicates, and anything inside another item that is kept.
    /// Paths are compared as given (only trailing slashes are removed), as Spotlight and restic see them.
    public static func collapse(
        _ marked: [String], sources: [String], exclusions: [String], backUpAnyway: [String]
    ) -> [String] {
        let sources = sources.map(trimmed)
        let excluded = Set(exclusions.compactMap(CloudOnlyScope.unescapedLiteral).map(trimmed))
        let anyway = Set(backUpAnyway.map(trimmed))
        var candidates = Set<String>()
        for path in marked.map(trimmed) where path.hasPrefix("/") && path != "/" {
            guard sources.contains(where: { path != $0 && path.hasPrefix(CloudOnlyScope.directoryPrefix($0)) }),
                !CloudOnlyScope.isExcluded(path, by: excluded),
                !CloudOnlyScope.isExcluded(path, by: anyway),
                !anyway.contains(where: { $0.hasPrefix(CloudOnlyScope.directoryPrefix(path)) })
            else { continue }
            candidates.insert(path)
        }
        return candidates.filter { !hasAncestor($0, in: candidates) }.sorted()
    }

    /// True when a folder above `path` (not `path` itself) is in `set`.
    private static func hasAncestor(_ path: String, in set: Set<String>) -> Bool {
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = slash == current.startIndex ? "/" : String(current[..<slash])
            if set.contains(current) { return true }
            if current == "/" { return false }
        }
        return false
    }

    /// `path` without trailing slashes ("/" stays).
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: The exclude file

    /// What `excludeFile` writes, and which paths it could and couldn't write.
    public struct ExcludeFile: Sendable, Equatable {
        /// One pattern per line, each ending in a newline; empty for no paths.
        public var text: String
        /// The paths the text excludes, in order.
        public var written: [String]
        /// The paths left out because no line could mean exactly them: they are backed up.
        public var unrepresentable: [String]
    }

    /// The file for `--exclude-file`, one literal pattern per path (`excludeLine`).
    public static func excludeFile(_ paths: [String]) -> ExcludeFile {
        var file = ExcludeFile(text: "", written: [], unrepresentable: [])
        for path in paths {
            if let line = excludeLine(for: path) {
                file.text += line + "\n"
                file.written.append(path)
            } else {
                file.unrepresentable.append(path)
            }
        }
        return file
    }

    /// The exclude-file line that matches exactly `path`, or nil when there is none. restic 0.19.1 reads the file with
    /// `readPatternsFromFiles` (`internal/filter/exclude.go`): split into lines by `bufio.Scanner` (`\n`, and a `\r`
    /// before it dropped), `strings.TrimSpace`, a line starting with `#` skipped, then `os.Expand` with `$$` meaning `$`;
    /// the pattern is then `filepath.Clean`ed and matched with `filepath.Match` per component (`internal/filter/filter.go`).
    /// So:
    /// - glob characters and the backslash are escaped (`DefaultExclusions.escapedGlob`), and every `$` is doubled;
    /// - the path must be absolute (so no line starts with `#` or `!`) and already clean (no empty, `.` or `..`
    ///   component), or `filepath.Clean` would change what it names;
    /// - a newline or carriage return, or white space at the end (which `TrimSpace` would remove: the Unicode
    ///   White_Space property, checked on the last scalar as Go does per rune), can't be written: nil;
    /// - a line too long for the scanner would fail the backup: nil.
    public static func excludeLine(for path: String) -> String? {
        guard path.unicodeScalars.first == "/", path.unicodeScalars.count > 1,
            !path.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }),
            let last = path.unicodeScalars.last, !last.properties.isWhitespace,
            // Split by scalar, as Go does: a "/" followed by a combining mark is one Character but still a separator.
            path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && !$0.elementsEqual(".".unicodeScalars) && !$0.elementsEqual("..".unicodeScalars) })
        else { return nil }
        // `$` doubled per scalar too (`String.replacing` matches whole Characters, so it would miss "$" + a mark).
        var doubled = String.UnicodeScalarView()
        for scalar in DefaultExclusions.escapedGlob(path).unicodeScalars {
            if scalar == "$" { doubled.append(scalar) }
            doubled.append(scalar)
        }
        let line = String(doubled)
        return line.utf8.count <= maxLineBytes ? line : nil
    }
}

/// Spotlight's answer to `MarkedNotForBackup.spotlightQuery`.
public enum MarkedItemsQuery: Sendable, Equatable {
    /// The paths Spotlight listed. More than the limit asked for means the scan gives up.
    case found([String])
    /// The query couldn't be made or run.
    case failed
}

/// Where marked items are found: Spotlight's index, and the attribute itself. The real one is `SpotlightMarkedItems`;
/// tests inject fakes.
public protocol MarkedItemsFinding: Sendable {
    /// The indexed items carrying the attribute within `scopes` (absolute folders, `mdfind -onlyin`), at most
    /// `limit + 1` of them. Blocks the calling thread.
    func query(scopes: [String], limit: Int) -> MarkedItemsQuery
    /// True when `path` itself (no symlink followed) still carries the attribute. Metadata only: nothing is opened.
    func isMarked(_ path: String) -> Bool
    /// The gate `MarkedItemsScan.offPool` holds while a look at this finder is outstanding. The real finder's is
    /// process-wide (`MarkedItemsLookGate.spotlight`); each fake has its own, so parallel tests don't meet.
    var gate: MarkedItemsLookGate { get }
}

/// At most one look per finder at a time (review I2). A synchronous Spotlight query can't be stopped, so a hung `mds`
/// would otherwise leave one more blocked thread behind every look, without limit. The gate holds the outstanding
/// look's deadline: a look that arrives while one is outstanding waits for it within its own deadline (two plans
/// backing up together), but gives up at once when the outstanding one has already outlived its deadline (stuck), so
/// only that one thread is ever blocked.
public final class MarkedItemsLookGate: Sendable {
    /// The real Spotlight finder's, shared by every look in the process (the agent's backups, the app's What tab).
    public static let spotlight = MarkedItemsLookGate()

    /// The outstanding look's deadline; nil when none is outstanding.
    private let outstanding = Mutex<ContinuousClock.Instant?>(nil)

    public init() {}

    /// True while a look is outstanding.
    public var isBusy: Bool { outstanding.withLock { $0 != nil } }

    enum Entry: Equatable {
        case entered
        /// A look is outstanding, and is still within its deadline.
        case wait
        /// A look is outstanding past its deadline.
        case stuck
    }

    func enter(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Entry {
        outstanding.withLock { current in
            guard let current else {
                current = deadline
                return .entered
            }
            return now >= current ? .stuck : .wait
        }
    }

    func leave() { outstanding.withLock { $0 = nil } }
}

/// One look for marked items within a plan's sources, within a bound: Spotlight's candidates, each checked to still
/// carry the attribute (a stale index entry is dropped). The caller collapses the result for the plan.
public struct MarkedItemsScan: Sendable {
    public enum Result: Sendable, Equatable {
        /// The verified items, in Spotlight's order; empty is none (or none Spotlight could see).
        case found([String])
        /// Too many results, too slow, or the query failed: nothing extra is skipped and nothing is recorded.
        case gaveUp
        /// An earlier look is still outstanding past its deadline (Spotlight seems hung), so none was started: treated
        /// like `gaveUp`, but the agent logs it once per episode rather than at every backup.
        case busy
    }

    public var finder: any MarkedItemsFinding
    public var limit: Int
    /// True once the time limit has passed; asked before checking candidates, and every 256 of them.
    public var isOutOfTime: @Sendable () -> Bool

    public init(finder: any MarkedItemsFinding, limit: Int, isOutOfTime: @escaping @Sendable () -> Bool) {
        self.finder = finder
        self.limit = limit
        self.isOutOfTime = isOutOfTime
    }

    /// Blocks the calling thread: call it off the cooperative pool (`offPool`).
    public func run(sources: [String]) -> Result {
        var seen = Set<String>()
        let scopes = sources.map(MarkedNotForBackup.trimmed).filter { seen.insert($0).inserted }
        guard !scopes.isEmpty else { return .found([]) }
        guard case .found(let candidates) = finder.query(scopes: scopes, limit: limit), candidates.count <= limit else {
            return .gaveUp
        }
        var verified: [String] = []
        for (index, path) in candidates.enumerated() {
            if index % 256 == 0, isOutOfTime() { return .gaveUp }
            if finder.isMarked(path) { verified.append(path) }
        }
        return .found(verified)
    }

    /// Runs the scan on a thread of its own (the synchronous Spotlight query blocks it, so it stays off the
    /// cooperative pool) and returns its result, or `.gaveUp` at `deadline` seconds, whichever comes first. A
    /// synchronous `MDQueryExecute` can't be cut short from outside (an `MDQueryStop` from a run-loop timer on its own
    /// thread didn't end it early, tested on macOS 27), so a query still running at the deadline finishes on its own
    /// thread later and its result is discarded; it touches nothing but its own locals.
    ///
    /// The finder's `gate` keeps it to one outstanding look: while another is outstanding and within its deadline this
    /// waits for it (polling, within this look's own deadline); when the outstanding one is past its deadline, or this
    /// look's deadline passes or its task is cancelled while waiting, it returns `.busy` without starting a thread.
    public static func offPool(
        finder: any MarkedItemsFinding, sources: [String], limit: Int = MarkedNotForBackup.resultLimit,
        deadline: TimeInterval = MarkedNotForBackup.timeLimit
    ) async -> Result {
        let end = ContinuousClock.now.advanced(by: .seconds(deadline))
        let gate = finder.gate
        while true {
            let now = ContinuousClock.now
            switch gate.enter(until: end, now: now) {
            case .entered: break
            case .stuck: return .busy
            case .wait:
                if now >= end { return .busy }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return .busy }
                continue
            }
            break
        }
        let scan = MarkedItemsScan(finder: finder, limit: limit, isOutOfTime: { ContinuousClock.now >= end })
        let remaining = max(0, ContinuousClock.now.duration(to: end) / .seconds(1))
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let thread = Thread {
                let result = scan.run(sources: sources)
                // Only when the query has really returned: a timed-out look keeps the gate until then.
                gate.leave()
                once.resume(result)
            }
            thread.qualityOfService = .utility
            thread.name = "Restorey marked-items scan"
            thread.start()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { once.resume(.gaveUp) }
        }
    }
}

/// The What tab's sheet: each outer marked item with a "Back up anyway" checkbox, and the count its line shows. The same
/// collapse as the agent's, so the sheet lists what a backup would skip.
public enum MarkedItemsList {
    public struct Row: Sendable, Equatable, Identifiable {
        public var path: String
        /// `~` for the home folder.
        public var display: String
        /// The person chose to back it up (it, or a folder above it, is in `backUpAnyway`).
        public var backedUpAnyway: Bool
        /// An entry for a folder above it is what backs it up: unticking this row can't change that (the entry covers
        /// other items too), so the sheet disables its checkbox. Only an entry the sheet didn't make can do this.
        public var coveredByEntryAbove: Bool
        public var id: String { path }

        public init(path: String, display: String, backedUpAnyway: Bool, coveredByEntryAbove: Bool) {
            self.path = path
            self.display = display
            self.backedUpAnyway = backedUpAnyway
            self.coveredByEntryAbove = coveredByEntryAbove
        }
    }

    /// The marked items as they collapse with no "Back up anyway" entries, so a ticked item stays listed (and the
    /// items inside it stay folded into it); each is ticked when the plan's entries keep it out of the skipped list.
    public static func rows(
        verified: [String], sources: [String], exclusions: [String], backUpAnyway: [String], home: URL
    ) -> [Row] {
        let skipped = Set(MarkedNotForBackup.collapse(
            verified, sources: sources, exclusions: exclusions, backUpAnyway: backUpAnyway))
        let entries = backUpAnyway.map(MarkedNotForBackup.trimmed)
        return MarkedNotForBackup.collapse(verified, sources: sources, exclusions: exclusions, backUpAnyway: []).map { path in
            Row(
                path: path, display: MarkedNotForBackupText.displayPath(path, home: home),
                backedUpAnyway: !skipped.contains(path),
                coveredByEntryAbove: entries.contains { $0 != path && path.hasPrefix(CloudOnlyScope.directoryPrefix($0)) })
        }
    }

    /// How many items a backup would skip: the count the agent records.
    public static func skippedCount(verified: [String], sources: [String], exclusions: [String], backUpAnyway: [String]) -> Int {
        MarkedNotForBackup.collapse(verified, sources: sources, exclusions: exclusions, backUpAnyway: backUpAnyway).count
    }

    /// `entries` with `path` ticked (added once) or unticked: then the entry for the path and any inside it go. An
    /// entry above it stays (it covers other items too); such a row is `coveredByEntryAbove` and can't be unticked.
    public static func settingBackUpAnyway(_ on: Bool, for path: String, in entries: [String]) -> [String] {
        if on { return entries.contains(path) ? entries : entries + [path] }
        let inside = CloudOnlyScope.directoryPrefix(path)
        return entries.filter { entry in
            let trimmed = MarkedNotForBackup.trimmed(entry)
            return trimmed != path && !trimmed.hasPrefix(inside)
        }
    }
}

/// The words for items apps mark as not for backup, in the What tab and its sheet. Information, never a warning.
public enum MarkedNotForBackupText {
    static let items = "items apps mark as not for backup"

    /// "Also skipped: 1,145 items apps mark as not for backup" ("1 item"), the count grouped for `locale`; without a
    /// count (still checking, or the look gave up) or with none found, the same words without a number. When the plan
    /// doesn't skip them: "Items apps mark as not for backup are included".
    public static func line(count: Int?, skips: Bool, locale: Locale) -> String {
        guard skips else { return "Items apps mark as not for backup are included" }
        switch count {
        case nil: return "Also skipped: \(items)"
        case 0?: return "Also skipped: \(items) (none found)"
        case 1?: return "Also skipped: 1 item apps mark as not for backup"
        case let count?: return "Also skipped: \(count.formatted(.number.locale(locale))) \(items)"
        }
    }

    /// Under the What tab's line and above the sheet's list when the app lacks Full Disk Access (the agent's last
    /// probe): the app reads the attribute itself, and can't in protected folders, so those items drop out of its
    /// list. Backups are unaffected (the agent checks for itself). Nil with access.
    public static func incompleteNote(fullDiskAccessMissing: Bool) -> String? {
        fullDiskAccessMissing ? "This list may be incomplete until Restorey has Full Disk Access." : nil
    }

    /// `path` with the home folder shown as `~`.
    public static func displayPath(_ path: String, home: URL) -> String {
        let h = MarkedNotForBackup.trimmed(home.path)
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}
