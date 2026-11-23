import Testing
@testable import RestoreyCore

/// Other file systems mounted inside a plan's folders (fix, 23 Nov 2026). restic's `--one-file-system` skips what is
/// inside them but keeps the mount-point folder, and saving that folder reads its attributes from the mounted file
/// system: CoreDevice's DeviceFS fails that read on every run ("file too large"). So the mount points restic would keep
/// only as an empty folder are excluded outright, as Time Machine does.
@Suite struct OtherFileSystemsTests {
    typealias Mount = OtherFileSystems.Mount

    /// The owner's Mac: the home folder as the source, DeviceFS and OrbStack's NFS view mounted inside it, other volumes
    /// elsewhere.
    @Test func mountsInsideASourceOnAnotherDeviceAreListed() {
        let mounts = [
            Mount(path: "/", device: 1),
            Mount(path: "/System/Volumes/Data", device: 1),
            Mount(path: "/Users/x/Library/Developer/CoreDevice/DeviceFS", device: 5),
            Mount(path: "/Users/x/OrbStack", device: 6),
            Mount(path: "/Volumes/USB", device: 7),
        ]
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/Users/x"], sourceDevices: [1]) == [
            "/Users/x/Library/Developer/CoreDevice/DeviceFS", "/Users/x/OrbStack",
        ])
    }

    /// restic allows every source's device (`RejectByDevice`), so a mount on one of them isn't another file system to
    /// restic: with `/` as a source, the Data volume (the same device `/` reports) stays in.
    @Test func aMountOnASourcesOwnDeviceIsNotListed() {
        let mounts = [Mount(path: "/System/Volumes/Data", device: 1), Mount(path: "/Volumes/USB", device: 7)]
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/"], sourceDevices: [1]) == ["/Volumes/USB"])
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/", "/Volumes/USB"], sourceDevices: [1, 7]).isEmpty)
    }

    /// A drive listed as a source, or the volume a listed folder is on, is never left out: the person chose it.
    @Test func aSourceOrAFolderAboveOneIsNeverListed() {
        let mounts = [Mount(path: "/Volumes/USB", device: 7)]
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/Volumes/USB"], sourceDevices: [7]).isEmpty)
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/Volumes/USB/Photos"], sourceDevices: [7]).isEmpty)
        // Even when its device couldn't be read.
        #expect(OtherFileSystems.mountPoints(
            [Mount(path: "/Volumes/USB", device: nil)], sources: ["/Volumes/USB/Photos"], sourceDevices: []).isEmpty)
    }

    /// A mount point whose device couldn't be read is still another file system (it is in the mount table); restic
    /// couldn't save it either.
    @Test func aMountWhoseDeviceCouldNotBeReadIsListed() {
        #expect(OtherFileSystems.mountPoints(
            [Mount(path: "/Users/x/Share", device: nil)], sources: ["/Users/x"], sourceDevices: [1]) == ["/Users/x/Share"])
    }

    /// Whole path components: `/Users/xy` isn't inside `/Users/x`.
    @Test func onlyMountsInsideASourceByWholeComponentsAreListed() {
        let mounts = [Mount(path: "/Users/xy/Share", device: 5), Mount(path: "/Users/x/Share/", device: 6)]
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/Users/x/"], sourceDevices: [1]) == ["/Users/x/Share"])
    }

    /// One inside another left-out mount adds nothing: restic never reaches it.
    @Test func aMountInsideAnotherListedOneIsDropped() {
        let mounts = [Mount(path: "/Users/x/a/b", device: 6), Mount(path: "/Users/x/a", device: 5)]
        #expect(OtherFileSystems.mountPoints(mounts, sources: ["/Users/x"], sourceDevices: [1]) == ["/Users/x/a"])
    }
}
