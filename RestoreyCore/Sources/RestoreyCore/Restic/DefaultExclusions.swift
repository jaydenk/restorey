import Foundation

/// The exclusions a new plan starts with.
public enum DefaultExclusions {
    /// Time Machine's fixed-path exclusion list. It may not exist on every macOS release, in which
    /// case it is simply left out.
    static let systemStandardExclusionsPlist = URL(
        fileURLWithPath: "/System/Library/CoreServices/backupd.bundle/Contents/Resources/StdExclusions.plist")

    /// Only `StdExclusions.plist` is read from the real system; everything else is computed from
    /// `home`, so tests can pass a fake home. Internal on purpose: production callers must use
    /// `paths(home:identity:)` so Restorey's own folders cannot be forgotten.
    static func paths(home: URL) -> [String] {
        paths(home: home, standardExclusionsPlist: systemStandardExclusionsPlist)
    }

    /// `paths(home:)` plus Restorey's own logs and Application Support folders for `identity`.
    ///
    /// Restorey writes to these on every run. Left in a home-folder source they would change each
    /// hour and defeat `--skip-if-unchanged`, giving a new snapshot every run. The caches folder is
    /// already covered by `~/Library/Caches`.
    public static func paths(home: URL, identity: Identity) -> [String] {
        paths(home: home, identity: identity, standardExclusionsPlist: systemStandardExclusionsPlist)
    }

    static func paths(home: URL, identity: Identity, standardExclusionsPlist: URL?) -> [String] {
        var result = paths(home: home, standardExclusionsPlist: standardExclusionsPlist)
        let h = home.path
        for own in [
            "\(h)/Library/Logs/\(identity.logsDirectoryName)",
            "\(h)/Library/Application Support/\(identity.rootID)",
        ] where !result.contains(own) { result.append(own) }
        return result
    }

    static func paths(home: URL, standardExclusionsPlist: URL?) -> [String] {
        let h = home.path
        var result = [
            "\(h)/Library/Caches",
            "\(h)/.Trash",
            "**/node_modules",
            // Docker Desktop and OrbStack keep multi-gigabyte VM disk images that change constantly.
            "\(h)/Library/Containers/com.docker.docker/Data/vms",
            "\(h)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
        ]
        if let plist = standardExclusionsPlist, let extra = standardExclusions(at: plist, home: h) {
            for path in extra where !result.contains(path) { result.append(path) }
        }
        return result
    }

    /// `UserPathsExcluded` entries are relative to the home directory; `PathsExcluded` are absolute.
    private static func standardExclusions(at url: URL, home: String) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let user = (plist["UserPathsExcluded"] as? [String] ?? []).map { relative in
            "\(home)/\(relative.trimmingTrailingSlashes())"
        }
        let system = (plist["PathsExcluded"] as? [String] ?? []).map { $0.trimmingTrailingSlashes() }
        return user + system
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var s = Substring(self)
        while s.count > 1, s.last == "/" { s = s.dropLast() }
        return String(s)
    }
}
