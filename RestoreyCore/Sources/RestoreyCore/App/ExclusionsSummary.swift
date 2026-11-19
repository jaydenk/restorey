import Foundation

/// The one line setup's sources step shows for what a plan leaves out (UI design §4 step 5), before
/// "Review exclusions…". The defaults get the mockup's wording; anything changed is counted instead.
public enum ExclusionsSummary {
    /// - Parameter mentionsMarkedItems: names the items apps mark as not for backup when the plan skips them (Task
    ///   15c). The Folders tab passes false: it shows them on a line of their own, with a count.
    public static func line(plan: Plan, home: URL, identity: Identity, mentionsMarkedItems: Bool = true) -> String {
        let marked = mentionsMarkedItems && plan.skipsItemsMarkedNotForBackup
        let defaults = plan.exclusions == DefaultExclusions.paths(home: home, identity: identity)
            && plan.fileTypeExclusions == DefaultExclusions.fileTypes && plan.oneFileSystem
            && plan.skipsItemsMarkedNotForBackup
        if defaults {
            return "Skipped by default: caches, Trash, node_modules, VM and disk images, iCloud files not on this Mac"
                + (marked ? ", items apps mark as not for backup" : "")
                + " (Time Machine’s list, plus Backblaze’s file types)."
        }
        var parts = [
            count(plan.exclusions.count, "folder", "folders"),
            count(plan.fileTypeExclusions.count, "file type", "file types"),
        ]
        if plan.oneFileSystem { parts.append("other file systems inside these folders") }
        parts.append("iCloud files not on this Mac")
        if marked { parts.append("items apps mark as not for backup") }
        return "Skipped: " + parts.dropLast().joined(separator: ", ") + " and " + parts.last! + "."
    }

    /// The folder the Exclusions sheet shows as a fixed first row, "This plan’s backups": the plan's repository when it is
    /// a local folder inside one of the sources (v0.1.1, Task 2). The agent leaves it out of every backup itself, so it is
    /// never in the plan's `exclusions`; this only decides whether the sheet says so. Nil when there is nothing to show.
    public static func repositoryRow(repository: Repository?, sources: [String]) -> String? {
        guard let path = repository?.localFolderPath else { return nil }
        return sources.contains { SourcePaths.containsFollowingLinks($0, path) } ? path : nil
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}
