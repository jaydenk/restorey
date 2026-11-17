import Foundation

/// A backup's biggest additions as History and the Overview show them (Task 16d): the one line, and the record's
/// lists behind its "Show…". Information only.
public struct BiggestAdditionsSummary: Sendable, Equatable {
    /// "Biggest additions: Photos.sqlite 1.1 GB, big.log 20 MB, index.db 300 kB".
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

    /// The line for `additions`: the biggest files by name. Nil when there is nothing to name (no record of them, or no
    /// file added data), so no line and no "Show…" appear.
    public static func line(_ additions: BiggestAdditions?, locale: Locale) -> String? {
        guard let additions, !additions.files.isEmpty else { return nil }
        let named = additions.files.prefix(filesInLine).map { "\(name($0.path)) \(DisplayFormat.size($0.bytesAdded, locale: locale))" }
        return "Biggest additions: " + named.joined(separator: ", ")
    }

    /// History's line and lists for `record`: any backup whose record kept them.
    public static func summary(record: RunRecord, locale: Locale) -> BiggestAdditionsSummary? {
        guard case .backup = record.operation, let additions = record.biggestAdditions,
            let line = line(additions, locale: locale)
        else { return nil }
        return BiggestAdditionsSummary(line: line, additions: additions)
    }

    /// The Overview's: the same, only when the backup added more than `overviewThreshold` to the repository.
    public static func overviewSummary(record: RunRecord, locale: Locale) -> BiggestAdditionsSummary? {
        guard let packed = record.summary?.dataAddedPacked, Int64(packed) > overviewThreshold else { return nil }
        return summary(record: record, locale: locale)
    }

    /// The sheet's line under its title.
    public static func caption(_ additions: BiggestAdditions, locale: Locale) -> String {
        "Files added \(DisplayFormat.size(additions.totalBytesAdded, locale: locale)) to the repository, after compression. "
            + "These added the most."
    }

    /// Said under the folders when some weren't counted.
    public static let foldersIncompleteNote = "This backup changed too many folders to count them all, so a folder may be missing."

    /// The one line a backup's run log gets (Task 16d): every file and folder the record keeps, with full paths. The
    /// sizes are written as the app shows them, in Australian English, whatever the Mac's locale.
    public static func logLine(_ additions: BiggestAdditions?) -> String {
        guard let additions else { return "Biggest additions: restic didn't report them" }
        guard !additions.files.isEmpty else { return "Biggest additions: no file added data" }
        let size = { (bytes: Int64) in DisplayFormat.size(bytes, locale: logLocale) }
        let files = additions.files.map { "\($0.path) \(size($0.bytesAdded))" }.joined(separator: ", ")
        let folders = additions.folders.map { "\($0.path) \(size($0.bytesAdded))" }.joined(separator: ", ")
        return "Biggest additions (files added \(size(additions.totalBytesAdded)) to the repository): \(files); by folder: \(folders)"
            + (additions.foldersIncomplete ? " (too many folders to count them all)" : "")
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
