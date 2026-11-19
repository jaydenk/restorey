import Foundation

/// Where one backup folder lies against another: the one place paths are compared for containment (Task 1).
public enum SourcePaths {
    /// Whether `inner` is `outer` or lies below it, by whole path components (`/Users/me/Doc` doesn't contain
    /// `/Users/me/Documents`). Paths are compared standardised (trailing slashes and `..` don't matter) and
    /// symlink-resolved (a folder reached through a link is the place the link leads to); either form matching counts.
    public static func contains(_ outer: String, _ inner: String) -> Bool {
        components(outer, resolving: false).isPrefix(of: components(inner, resolving: false))
            || components(outer, resolving: true).isPrefix(of: components(inner, resolving: true))
    }

    private static func components(_ path: String, resolving: Bool) -> [String] {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        if resolving { url = url.resolvingSymlinksInPath() }
        return url.pathComponents
    }
}

private extension Array where Element == String {
    func isPrefix(of other: [String]) -> Bool { other.starts(with: self) }
}
