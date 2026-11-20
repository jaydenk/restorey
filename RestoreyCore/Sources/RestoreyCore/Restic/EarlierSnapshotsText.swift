import Foundation

/// The words around the earlier-snapshots actions (UI design §4 step 3 and §6.2, Task 14b), in the product spec's terms.
public enum EarlierSnapshotsText {
    /// An NSAlert's text: a destructive confirmation whose default button is Cancel.
    public struct Confirmation: Sendable, Equatable {
        public var title: String
        public var message: String
        /// The destructive button, "Remove 12 Snapshots".
        public var button: String
    }

    /// The confirmation for `group`. `afterFirstBackup`: setup's, where the removal waits for the plan's first
    /// successful backup. Prune frees the space only where the plan prunes; otherwise the data stays.
    ///
    /// Kept short on purpose (fix round 2, live finding L3): macOS lays a modern alert out in a narrow column with its
    /// buttons stacked, so every sentence adds lines, and the first wording (about 430 characters) made a 514 pt sheet,
    /// taller than the setup window. The longest case stays under 240 characters (`EarlierSnapshotsConfirmationLengthTests`).
    public static func confirmation(
        _ group: EarlierSnapshotGroup, pruneEnabled: Bool, afterFirstBackup: Bool, home: String = NSHomeDirectory()
    ) -> Confirmation {
        let n = group.removeIDs.count
        let keeps = group.keptCount == 0 ? "keeps none" : "keeps \(group.keptCount)"
        let title: String
        var message: String
        switch group.scope {
        case .beforeAdoption:
            title = "Remove \(snapshots(n)) from before Restorey?"
            message = "Retention \(keeps) of the \(snapshots(group.total)) of these folders from this Mac, other tools’ included"
            message += afterFirstBackup ? "; the rest go after the first successful backup." : "."
            message += " Other Macs and folders aren’t touched."
        case .previousFolderList:
            title = "Remove \(snapshots(n)) of the previous folder list?"
            message = "Retention \(keeps) of the \(snapshots(group.total)) of \(folders(group.paths, home: home))."
        }
        message += pruneEnabled ? " Prune frees the space later." : " Prune is off: the data stays."
        message += " This can’t be undone."
        return Confirmation(title: title, message: message, button: "Remove \(n) \(n == 1 ? "Snapshot" : "Snapshots")")
    }

    /// The Retention tab's line for one group.
    public static func row(_ group: EarlierSnapshotGroup, home: String = NSHomeDirectory()) -> String {
        let n = group.removeIDs.count
        let removes = "retention would remove \(n == 0 ? "none" : String(n))."
        switch group.scope {
        case .beforeAdoption:
            return "Before Restorey: \(snapshots(group.total)) from \(group.host); \(removes)"
        case .previousFolderList:
            return "Previous folder list \(folders(group.paths, home: home)): \(snapshots(group.total)); \(removes)"
        }
    }

    /// The Retention tab's one line when there is nothing to apply, or nil when some group has snapshots to remove.
    public static func nothingToApply(_ preview: EarlierSnapshotsPreview) -> String? {
        if preview.groups.isEmpty {
            return "No earlier snapshots from this Mac to apply retention to."
        }
        return preview.hasAnythingToRemove ? nil : "Nothing to apply: retention keeps every earlier snapshot."
    }

    /// What a finished removal says.
    public static func removed(_ removal: EarlierSnapshotsRemoval) -> String {
        var text = removal.removed == 0
            ? "No snapshots were removed."
            : "Removed \(removal.removed) earlier \(removal.removed == 1 ? "snapshot" : "snapshots")."
        if removal.leftAlone > 0 {
            text += removal.leftAlone == 1
                ? " 1 confirmed snapshot was left: it had gone, or retention now keeps it."
                : " \(removal.leftAlone) confirmed snapshots were left: they had gone, or retention now keeps them."
        }
        return text
    }

    /// History's outcome for a removal record (`ResticOperation.forgetSnapshots`) that succeeded.
    public static func historyOutcome(removed: Int) -> String {
        removed == 0 ? "No earlier snapshots needed removing" : "Removed \(removed) earlier \(removed == 1 ? "snapshot" : "snapshots")"
    }

    private static func snapshots(_ n: Int) -> String { "\(n) \(n == 1 ? "snapshot" : "snapshots")" }

    private static func folders(_ paths: [String], home: String) -> String {
        paths.map { FormValidation.displayPath($0, home: home) }.joined(separator: ", ")
    }
}
