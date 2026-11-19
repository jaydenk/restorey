import Foundation

/// Where one backup folder lies against another: the one place paths are compared for containment (Task 1).
///
/// Two entry points, so a caller can't follow links by accident (final review I1):
/// - `containsByPath` compares the paths as written and never touches the file system. It is the one for validation
///   and anything on the agent's status and scheduling path (`Plan.validationErrors()`, `nextRunDate`), which a
///   repository on a hung network volume must not be able to stall.
/// - `containsFollowingLinks` also compares where links lead, which reads the file system (an `lstat` per component)
///   and can block for as long as a volume doesn't answer. It is for where the user acts: the app adding folders
///   (`FolderDrop`) and `AgentState.savePlan` (through `Plan.sourcesInsideRepositoryFollowingLinks()`, off the actor).
public enum SourcePaths {
    /// Whether `inner` is `outer` or lies below it, by whole path components (`/Users/me/Doc` doesn't contain
    /// `/Users/me/Documents`). Compared standardised (trailing slashes, `.` and `..` don't matter), as written: a link
    /// is judged by its own path, not where it leads. Never reads the file system.
    public static func containsByPath(_ outer: String, _ inner: String) -> Bool {
        components(inner).starts(with: components(outer))
    }

    /// `containsByPath`, or the same comparison of where both paths lead once links are resolved (a folder reached
    /// through a link is the place the link leads to). Reads the file system: never call it on the agent's actor.
    public static func containsFollowingLinks(_ outer: String, _ inner: String) -> Bool {
        containsByPath(outer, inner) || containsByPath(resolvingLinks(outer), resolvingLinks(inner))
    }

    /// `path` with `.`, `..` and repeated or trailing slashes removed, as written: `/a/x/../b/` is `/a/b`. Pure: unlike
    /// `URL(fileURLWithPath:)`, which asks the file system whether the path is a folder, it reads nothing.
    public static func standardised(_ path: String) -> String {
        let parts = components(path)
        return path.hasPrefix("/") ? "/" + parts.joined(separator: "/") : parts.joined(separator: "/")
    }

    /// Where `path` leads once every link in it is followed. Reads the file system.
    public static func resolvingLinks(_ path: String) -> String {
        URL(fileURLWithPath: standardised(path), isDirectory: true).resolvingSymlinksInPath().path
    }

    /// `resolvingLinks`, run off the caller's actor: an actor waiting for a volume that doesn't answer stays free to
    /// serve everything else while it waits.
    public static func resolvingLinksOffActor(_ path: String) async -> String {
        await Task.detached { resolvingLinks(path) }.value
    }

    private static func components(_ path: String) -> [Substring] {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts
    }
}
