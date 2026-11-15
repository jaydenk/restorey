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
    public static func confirmation(
        _ group: EarlierSnapshotGroup, pruneEnabled: Bool, afterFirstBackup: Bool, home: String = NSHomeDirectory()
    ) -> Confirmation {
        let n = group.removeIDs.count
        let title: String
        let whose: String
        switch group.scope {
        case .beforeAdoption:
            title = "Remove \(snapshots(n)) taken on \(group.host) before Restorey?"
            whose = "\(snapshots(group.total)) this Mac made of these folders before Restorey"
        case .previousFolderList:
            title = "Remove \(snapshots(n)) from the previous folder list?"
            whose = "\(snapshots(group.total)) of \(folders(group.paths, home: home))"
        }
        let when = afterFirstBackup ? " once the first backup has succeeded" : ""
        let keeps = group.keptCount == 0 ? "keeps none" : "keeps \(group.keptCount)"
        var message = "Applied as if they were this plan's own, its retention removes \(n) of the \(whose)\(when), and \(keeps)."
        if case .beforeAdoption = group.scope {
            message += " That includes other tools' snapshots of these folders from this Mac before Restorey. Snapshots from"
                + " other Macs, other Restorey plans and other folders are never touched."
        }
        message += pruneEnabled
            ? " The space \(n == 1 ? "it uses" : "they use") is freed at the plan's next prune."
            : " Their data stays in the repository while prune is off for this plan."
        message += " This can't be undone."
        return Confirmation(title: title, message: message, button: "Remove \(n) \(n == 1 ? "Snapshot" : "Snapshots")")
    }

    /// The Keep tab's line for one group.
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

    /// The Keep tab's one line when there is nothing to apply, or nil when some group has snapshots to remove.
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
