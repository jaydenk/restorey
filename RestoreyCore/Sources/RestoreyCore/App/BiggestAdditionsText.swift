import Foundation

/// A backup's biggest additions as History and the Overview show them (Task 16d): the one line, and the record's
/// lists behind its "Show…". Information only.
public struct BiggestAdditionsSummary: Sendable, Equatable {
    /// "Biggest additions: Photos.sqlite 1.1 GB, big.log 20 MB, index.db 300 kB", and in History
    /// " · folder listings 1.3 GB" after it (Task 16f).
    public var line: String
    public var additions: BiggestAdditions

    public init(line: String, additions: BiggestAdditions) {
        self.line = line
        self.additions = additions
    }
}

/// Words for a backup's biggest additions (Task 16d). Sizes are the app's own (`DisplayFormat.size`, decimal as restic
/// counts them) and are what the data took in the repository, after compression and encryption.
public enum BiggestAdditionsText {
    /// How many files the one line names.
    static let filesInLine = 3
    /// The Overview names the last backup's biggest additions only when it added more than this to the repository
    /// (`data_added_packed`): 100 MB.
    public static let overviewThreshold: Int64 = 100_000_000
    /// History's line names the folder listings from this size (Task 16f): 1 MB.
    public static let listingsInLineThreshold: Int64 = 1_000_000
    /// The run log notes it when the files and folder listings come to less than this share of restic's
    /// `data_added_packed` (Task 16f), so the difference can be looked into.
    static let shortfallShare = 0.9

    /// The line for `additions`: the biggest files by name. Nil when there is nothing to name (no record of them, or no
    /// file added data), so no line and no "Show…" appear.
    public static func line(_ additions: BiggestAdditions?, locale: Locale) -> String? {
        guard let additions, !additions.files.isEmpty else { return nil }
        let named = additions.files.prefix(filesInLine).map { "\(name($0.path)) \(DisplayFormat.size($0.bytesAdded, locale: locale))" }
        return "Biggest additions: " + named.joined(separator: ", ")
    }

    /// History's line and lists for `record`: any backup whose record kept them. The line ends with what the folder
    /// listings added when that is at least `listingsInLineThreshold` (Task 16f); a backup that added only listings
    /// that size names them alone ("Biggest additions: folder listings 1.3 GB"), so its "Show…" is still there.
    public static func summary(record: RunRecord, locale: Locale) -> BiggestAdditionsSummary? {
        guard case .backup = record.operation, let additions = record.biggestAdditions else { return nil }
        let files = line(additions, locale: locale)
        guard let listings = additions.listingsBytesAdded, listings >= listingsInLineThreshold else {
            return files.map { BiggestAdditionsSummary(line: $0, additions: additions) }
        }
        let named = "folder listings \(DisplayFormat.size(listings, locale: locale))"
        return BiggestAdditionsSummary(
            line: files.map { $0 + " · " + named } ?? "Biggest additions: " + named, additions: additions)
    }

    /// The Overview's: the files only, and only when the backup added more than `overviewThreshold` to the repository.
    /// The folder listings are in History's line and the sheet.
    public static func overviewSummary(record: RunRecord, locale: Locale) -> BiggestAdditionsSummary? {
        guard let packed = record.summary?.dataAddedPacked, Int64(packed) > overviewThreshold else { return nil }
        return filesSummary(record: record, locale: locale)
    }

    private static func filesSummary(record: RunRecord, locale: Locale) -> BiggestAdditionsSummary? {
        guard case .backup = record.operation, let additions = record.biggestAdditions,
            let line = line(additions, locale: locale)
        else { return nil }
        return BiggestAdditionsSummary(line: line, additions: additions)
    }

    /// The sheet's line under its title.
    public static func caption(_ additions: BiggestAdditions, locale: Locale) -> String {
        guard !additions.files.isEmpty || (additions.listingsBytesAdded ?? 0) <= 0 else {
            return "No file added data to the repository; the folder listings below did."
        }
        return "Files added \(DisplayFormat.size(additions.totalBytesAdded, locale: locale)) to the repository, after compression. "
            + "These added the most."
    }

    /// The sheet's line under its lists about the folder listings (Task 16f); nil when the record has none to tell.
    public static func listingsNote(_ additions: BiggestAdditions, locale: Locale) -> String? {
        guard let listings = additions.listingsBytesAdded, listings > 0 else { return nil }
        return "Folder listings: \(DisplayFormat.size(listings, locale: locale)) — restic records each changed folder’s list "
            + "of files; a change anywhere in a folder rewrites its list and the lists of the folders above it."
    }

    /// Said under the folders when some weren't counted.
    public static let foldersIncompleteNote = "This backup changed too many folders to count them all, so a folder may be missing."

    /// The one line a backup's run log gets (Task 16d): every file and folder the record keeps, with full paths. The
    /// sizes are written as the app shows them, in Australian English, whatever the Mac's locale.
    public static func logLine(_ additions: BiggestAdditions?) -> String {
        guard let additions else { return "Biggest additions: restic didn't report them" }
        let size = { (bytes: Int64) in DisplayFormat.size(bytes, locale: logLocale) }
        guard !additions.files.isEmpty else {
            guard let listings = additions.listingsBytesAdded, listings > 0 else { return "Biggest additions: no file added data" }
            return "Biggest additions: no file added data (folder listings \(size(listings)) to the repository)"
        }
        let files = additions.files.map { "\($0.path) \(size($0.bytesAdded))" }.joined(separator: ", ")
        let folders = additions.folders.map { "\($0.path) \(size($0.bytesAdded))" }.joined(separator: ", ")
        let listings = additions.listingsBytesAdded.map { ", folder listings \(size($0))" } ?? ""
        return "Biggest additions (files added \(size(additions.totalBytesAdded))\(listings) to the repository): \(files); "
            + "by folder: \(folders)" + (additions.foldersIncomplete ? " (too many folders to count them all)" : "")
    }

    /// A second run log line when the files and folder listings come to less than `shortfallShare` of what restic says
    /// the backup added (`data_added_packed`), so the difference can be looked into (Task 16f). restic's own total is
    /// the same sizes summed (`internal/archiver/archiver.go`, `Snapshot`), less only the root's own tree, which it never
    /// prints, so a real gap means lines were lost or restic counts something new. Nil when there's nothing to compare.
    public static func shortfallLogLine(_ additions: BiggestAdditions?, dataAddedPacked: Int?) -> String? {
        guard let additions, let listings = additions.listingsBytesAdded, let dataAddedPacked, dataAddedPacked > 0 else {
            return nil
        }
        let packed = Int64(dataAddedPacked)
        let (sum, overflow) = additions.totalBytesAdded.addingReportingOverflow(listings)
        let counted = overflow ? Int64.max : sum
        guard Double(counted) < Double(packed) * shortfallShare else { return nil }
        let size = { (bytes: Int64) in DisplayFormat.size(bytes, locale: logLocale) }
        return "Biggest additions: files (\(size(additions.totalBytesAdded))) and folder listings (\(size(listings))) come to "
            + "\(size(counted)), \(size(packed - counted)) less than the \(size(packed)) restic says the backup added to the "
            + "repository (data_added_packed)"
    }

    private static let logLocale = Locale(identifier: "en_AU")

    /// One row of the sheet.
    public struct Row: Sendable, Equatable, Identifiable {
        public var path: String
        /// `~` for the home folder.
        public var display: String
        public var size: String
        /// "Open in Finder" is offered: the path still exists.
        public var canOpenInFinder: Bool
        public var id: String { path }
    }

    public static func rows(
        _ entries: [BiggestAdditions.Entry], home: URL, locale: Locale, exists: (String) -> Bool
    ) -> [Row] {
        entries.map { entry in
            Row(
                path: entry.path, display: MarkedNotForBackupText.displayPath(entry.path, home: home),
                size: DisplayFormat.size(entry.bytesAdded, locale: locale), canOpenInFinder: exists(entry.path))
        }
    }

    /// The file's own name; the whole path when it has none.
    static func name(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }
}
