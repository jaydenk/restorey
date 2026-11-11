import Foundation

/// The exclusions a new plan starts with (spec §5.7, Ruling R64).
///
/// There is no Time Machine list to read: on macOS 27 `StdExclusions.plist` no longer exists (the list is
/// compiled into `/System/Library/CoreServices/TimeMachine/backupd`), so the folders below were found by
/// probing with `tmutil isexcluded` and by an EPERM survey of a whole home folder (Task 18). An earlier
/// reader for that plist silently applied nothing and was removed.
///
/// Patterns follow restic 0.19.1's rules (`internal/filter/filter.go`): matched against whole path
/// components, `*` doesn't cross `/`, `**` is a whole component, a leading `/` anchors at the root and a
/// relative pattern matches at any depth. `--exclude` expands neither `~` nor `$HOME`, so home paths are
/// written out in full, with any glob metacharacter in the home path escaped.
public enum DefaultExclusions {
    /// The folder list for `home`, without Restorey's own folders. Internal on purpose: production callers
    /// must use `paths(home:identity:)` so Restorey's own folders can't be forgotten.
    static func paths(home: URL) -> [String] {
        let h = escapedGlob(home.path)
        return [
            // Kept from v0.1's first list.
            "\(h)/Library/Caches",
            "\(h)/.Trash",
            "**/node_modules",
            // Docker Desktop and OrbStack keep multi-gigabyte VM disk images that change constantly.
            "\(h)/Library/Containers/com.docker.docker/Data/vms",
            "\(h)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
            // Time Machine's standard list (excluded with no per-item attribute set).
            "\(h)/Library/Logs",
            "\(h)/Library/Metadata/CoreSpotlight",
            "\(h)/Library/Mobile Documents/.Trash",
            // Time Machine's per-item exclusion attribute (com_apple_backup_excludeItem), set by macOS or
            // the owning app on these: rebuilt or re-downloaded state.
            "\(h)/Library/Saved Application State",
            "\(h)/Library/Developer/Xcode/DerivedData",
            "\(h)/Library/Developer/CoreSimulator",
            "\(h)/Library/Suggestions",
            "\(h)/Library/Biome",
            "\(h)/Library/Trial",
            "\(h)/Library/Application Support/CloudDocs/session/db",
            // Mail's index; the V<n> folder changes between macOS releases, and the file has -shm/-wal siblings.
            "**/Mail/V*/MailData/Envelope Index*",
            "\(h)/.cache",
            "\(h)/.npm",
            // Caches inside app containers (Time Machine excludes at least Mail's).
            "\(h)/Library/Containers/*/Data/Library/Caches",
            "\(h)/Library/Group Containers/*/Library/Caches",
            // The survey: these error on every run even with Full Disk Access.
            "\(h)/Library/Application Support/FileProvider/*/wharf",
            "\(h)/Library/Group Containers/group.com.apple.secure-control-center-preferences",
        ]
    }

    /// `paths(home:)` plus Restorey's own logs and Application Support folders for `identity`.
    ///
    /// Restorey writes to these on every run. Left in a home-folder source they would change each
    /// hour and defeat `--skip-if-unchanged`, giving a new snapshot every run. The logs folder is listed
    /// even though `~/Library/Logs` covers it, so this rule never depends on the rest of the list. The
    /// caches folder is covered by `~/Library/Caches`.
    public static func paths(home: URL, identity: Identity) -> [String] {
        var result = paths(home: home)
        let h = escapedGlob(home.path)
        for own in [
            "\(h)/Library/Logs/\(escapedGlob(identity.logsDirectoryName))",
            "\(h)/Library/Application Support/\(escapedGlob(identity.rootID))",
        ] where !result.contains(own) { result.append(own) }
        return result
    }

    /// File-type exclusions a new plan starts with (Ruling R64b), Backblaze-style: extensions without the
    /// dot, in lower case, matched case-insensitively at any depth (`--iexclude=*.<ext>`), so a VM bundle
    /// directory such as `Windows.pvm` is excluded whole. The person can add and remove entries per plan.
    /// Logs, Windows binaries, `.o` and sparse bundles are deliberately not on it.
    public static let fileTypes: [String] = [
        // Disk images.
        "dmg", "iso", "sparseimage",
        // Virtual machine disks, bundles and their state.
        "vmdk", "vhd", "vhdx", "vdi", "qcow2", "hdd", "hds", "pvm", "pvs", "pvi", "pva", "fdd", "vmc",
        "vmx", "vmxf", "vmsn", "vmsd", "vmem", "nvram", "mem", "vsv",
    ]

    /// `path` with the characters restic's matcher (Go's `filepath.Match`) treats specially escaped with a
    /// backslash, so a literal path matches only itself.
    static func escapedGlob(_ path: String) -> String {
        var result = ""
        for character in path {
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
