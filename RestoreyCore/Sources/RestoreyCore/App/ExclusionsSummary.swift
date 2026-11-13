import Foundation

/// The one line setup's sources step shows for what a plan leaves out (UI design §4 step 5), before
/// "Review exclusions…". The defaults get the mockup's wording; anything changed is counted instead.
public enum ExclusionsSummary {
    public static func line(plan: Plan, home: URL, identity: Identity) -> String {
        let defaults = plan.exclusions == DefaultExclusions.paths(home: home, identity: identity)
            && plan.fileTypeExclusions == DefaultExclusions.fileTypes && plan.oneFileSystem
        if defaults {
            return "Skipped by default: caches, Trash, node_modules, VM and disk images, iCloud files not on this "
                + "Mac (Time Machine's list, plus Backblaze's file types)."
        }
        var parts = [
            count(plan.exclusions.count, "folder", "folders"),
            count(plan.fileTypeExclusions.count, "file type", "file types"),
        ]
        if plan.oneFileSystem { parts.append("other file systems inside these folders") }
        parts.append("iCloud files not on this Mac")
        return "Skipped: " + parts.dropLast().joined(separator: ", ") + " and " + parts.last! + "."
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}
