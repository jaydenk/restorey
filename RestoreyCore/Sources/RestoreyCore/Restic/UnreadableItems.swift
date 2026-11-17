import Foundation

/// A file or folder a backup couldn't read, as kept on its `RunRecord` (Task 16b). `reason` is the short ending of
/// restic's message ("operation not permitted"), never the whole message: the record stays small, and the run's log
/// has the rest. Paths aren't secret.
public struct UnreadableItem: Codable, Sendable, Equatable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum UnreadableItems {
    /// The most items a record keeps. The warning's count stays exact; the sheet says "and N more" for the rest.
    public static let cap = 100
    /// A reason is cut here, so one odd message can't grow the state file.
    public static let maxReasonLength = 120

    /// The items a backup left out of its snapshot, for its record: the distinct `item`s of the errors restic raised
    /// while archiving, in the order restic reported them, each with the first reason given, up to `cap`. The same
    /// errors `unreadableFileCount` counts, so the list and the count agree (scan errors never change the snapshot,
    /// and an archival error without an item can't be shown). Nil when there are none, so the field is omitted.
    public static func collect(_ errors: [ResticItemError]) -> [UnreadableItem]? {
        var seen = Set<String>()
        var items: [UnreadableItem] = []
        for error in errors where error.during == "archival" {
            guard let path = error.item, seen.insert(path).inserted else { continue }
            items.append(UnreadableItem(path: path, reason: shortReason(message: error.message, item: path)))
            if items.count == cap { break }
        }
        return items.isEmpty ? nil : items
    }

    /// restic's message for an archival error is the Go error's text, which names the path
    /// ("open /a/b: operation not permitted"), and the archiver adds the path in front when the error lacks it
    /// (restic 0.19.1 `internal/archiver/archiver.go`, `Archiver.error`). The reason is what follows the last ": " once
    /// the path is taken out, so a path containing ": " doesn't split it.
    static func shortReason(message: String, item: String) -> String {
        var text = message
        if !item.isEmpty { text = text.replacingOccurrences(of: item, with: "") }
        // "open /a/b:" says nothing after the path.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") { return "" }
        if let separator = text.range(of: ": ", options: .backwards) {
            text = String(text[separator.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
        return String(text.prefix(maxReasonLength))
    }
}
