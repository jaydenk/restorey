import Darwin

/// Other file systems mounted inside a plan's folders (fix, 23 Nov 2026).
///
/// restic 0.19.1's `--one-file-system` skips everything inside another file system mounted under a source, but keeps
/// the mount-point folder itself (`RejectByDevice` in `internal/archiver/exclude.go`: "make sure we keep mountpoints").
/// Saving that folder reads its metadata and extended attributes, which come from the mounted file system, and that
/// read can fail: CoreDevice's DeviceFS (`~/Library/Developer/CoreDevice/DeviceFS`) lists a resource fork it then
/// can't return ("file too large"), so every backup of a home folder warned "1 file couldn't be read". Time Machine
/// leaves these out (`tmutil isexcluded` says Excluded). So, with one file system on, the runner passes the mount
/// points restic would keep only as an empty folder as literal exclusions, and restic never touches them.
public enum OtherFileSystems {
    /// A mounted file system: where it is mounted, and the device `lstat` reports for that folder (nil when it
    /// couldn't be read). The mount table's own `f_fsid` isn't used: for `/` it names the system volume while `lstat`
    /// (and so restic) reports the Data volume.
    public struct Mount: Sendable, Equatable {
        public var path: String
        public var device: UInt64?

        public init(path: String, device: UInt64?) {
            self.path = path
            self.device = device
        }
    }

    /// The mount points to leave out: each mounted strictly inside a source, on a device that is none of the sources'
    /// (restic allows every source's device), and neither a source nor a folder above one (the person chose those).
    /// One inside another listed mount point is dropped, since restic never reaches it. Standardised and sorted.
    public static func mountPoints(_ mounts: [Mount], sources: [String], sourceDevices: [UInt64]) -> [String] {
        let sources = sources.map(SourcePaths.standardised)
        let candidates = mounts.compactMap { mount -> String? in
            let path = SourcePaths.standardised(mount.path)
            guard sources.contains(where: { isInside(path, $0) }),
                  !sources.contains(where: { $0 == path || isInside($0, path) })
            else { return nil }
            if let device = mount.device, sourceDevices.contains(device) { return nil }
            return path
        }
        let kept = candidates.filter { path in !candidates.contains { isInside(path, $0) } }
        return Array(Set(kept)).sorted()
    }

    /// Whether `path` is strictly inside `folder`, by whole components.
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path != "/" && path.hasPrefix("/") : path.hasPrefix(folder + "/")
    }

    /// The mount points to leave out for `sources`, read from the mount table (`getmntinfo_r_np` with `MNT_NOWAIT`: a
    /// copy of its own, so calls on two threads don't share `getmntinfo`'s static buffer, and no waiting on a file
    /// system) and `lstat`, of the sources and of the mount points inside them only. Those `lstat` calls can block for
    /// as long as a volume doesn't answer, so only the runner calls this, through `LinkResolver.look` (its own thread
    /// and deadline).
    public static func current(sources: [String]) -> [String] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard count > 0, let table else { return [] }
        defer { free(table) }
        let standardised = sources.map(SourcePaths.standardised)
        let inside = (0..<Int(count)).compactMap { index -> String? in
            var entry = table[index]
            let path = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return standardised.contains { isInside(SourcePaths.standardised(path), $0) } ? path : nil
        }
        guard !inside.isEmpty else { return [] }
        return mountPoints(
            inside.map { Mount(path: $0, device: device($0)) }, sources: sources, sourceDevices: sources.compactMap(device))
    }

    /// The device `lstat` reports for `path`, as restic reads a source's (`newDeviceMap` lstats each one).
    private static func device(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(UInt32(bitPattern: info.st_dev)) : nil
    }
}
