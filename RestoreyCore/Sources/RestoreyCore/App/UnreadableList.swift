import Foundation

/// The files a warning backup couldn't read, as the Overview and History show them: the count with the items its
/// record kept (Task 16b). Information only: no outcome, icon, alert or ping depends on it.
public struct UnreadableSummary: Sendable, Equatable {
    /// The warning's exact count, which can be more than `items` (the record keeps the first 100).
    public var count: Int
    public var items: [UnreadableItem]

    public init(count: Int, items: [UnreadableItem]) {
        self.count = count
        self.items = items
    }

    /// Nil unless the record is a warning with items kept: records written before 16b have none, and the line then
    /// stays text.
    public init?(record: RunRecord) {
        guard case .warning(let unreadable) = record.outcome, let items = record.unreadableItems, !items.isEmpty else {
            return nil
        }
        self.init(count: unreadable, items: items)
    }
}

/// The "Files that couldn't be read" sheet's rows and edits. Pure: the sheet supplies the plan's exclusions and what
/// exists on disk.
public enum UnreadableList {
    public enum Action: Sendable, Equatable {
        /// Offer "Don't back this up", which adds `pattern` (`DefaultExclusions.pattern(forFolder:)`) to the plan.
        case dontBackUp(pattern: String)
        /// The form has the pattern: "Won't be backed up from the next backup" with Undo when `unsaved` (the saved plan
        /// doesn't have it yet, so Undo can take it back), otherwise "Already not backed up" (the saved plan has it).
        case excluded(unsaved: Bool)
        /// Nothing to exclude: it was deleted while the backup ran.
        case none
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var path: String
        /// `~` for the home folder.
        public var display: String
        /// The reason in plain words (`reasonWords`).
        public var reason: String
        public var action: Action
        /// "Open in Finder" is offered: the path still exists and the file wasn't deleted by the backup's own run.
        public var canOpenInFinder: Bool
        public var id: String { path }
    }

    static let deleted = "It was deleted while the backup ran"
    static let notAllowed = "Restorey isn’t allowed to read this"

    /// The reason in plain words: the common errno texts mapped, anything else restic's own text with a capital.
    public static func reasonWords(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("operation not permitted") || lower.contains("permission denied") { return notAllowed }
        if lower.contains("no such file or directory") { return deleted }
        guard let first = reason.first else { return "Restic gave no reason" }
        return first.uppercased() + reason.dropFirst()
    }

    public static func isDeleted(_ reason: String) -> Bool { reasonWords(reason) == deleted }

    /// "and 30 more" when the record kept fewer items than the warning counted; nil otherwise.
    public static func moreLine(count: Int, listed: Int) -> String? {
        count > listed ? "and \(count - listed) more" : nil
    }

    /// `exclusions` is the form's, `saved` the saved plan's: a pattern in the form but not yet saved is an edit still
    /// to undo (so reopening the sheet keeps Undo), one the saved plan has is "Already not backed up". A row is
    /// excluded when its pattern is in `exclusions` (the `/private/var` and `/var` spellings of one folder count as
    /// the same pattern, `SourcePaths`): the same check an undo makes, so undo and the row agree.
    public static func rows(
        items: [UnreadableItem], exclusions: [String], saved: [String], home: URL, exists: (String) -> Bool
    ) -> [Row] {
        items.map { item in
            let deleted = isDeleted(item.reason)
            let pattern = DefaultExclusions.pattern(forFolder: item.path)
            let action: Action
            if deleted {
                action = .none
            } else if contains(exclusions, pattern) {
                action = .excluded(unsaved: !contains(saved, pattern))
            } else {
                action = .dontBackUp(pattern: pattern)
            }
            return Row(
                path: item.path, display: MarkedNotForBackupText.displayPath(item.path, home: home),
                reason: reasonWords(item.reason), action: action, canOpenInFinder: !deleted && exists(item.path))
        }
    }

    /// Whether `patterns` holds `pattern`, or the same folder under its other `/private/tmp|var|etc` spelling. A
    /// pattern is a path with glob characters escaped, none of which is in those leading components.
    private static func contains(_ patterns: [String], _ pattern: String) -> Bool {
        patterns.contains { SourcePaths.sameFirmlinkSpelling($0, pattern) }
    }

    /// `exclusions` with the pattern for `path` added once.
    public static func adding(_ path: String, to exclusions: [String]) -> [String] {
        let pattern = DefaultExclusions.pattern(forFolder: path)
        return exclusions.contains(pattern) ? exclusions : exclusions + [pattern]
    }

    /// `exclusions` without the pattern for `path`.
    public static func removing(_ path: String, from exclusions: [String]) -> [String] {
        let pattern = DefaultExclusions.pattern(forFolder: path)
        return exclusions.filter { $0 != pattern }
    }
}
