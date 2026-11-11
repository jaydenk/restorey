import Foundation

/// A small HFS+ volume from a disk image, for testing a full disk without filling the real one. Always
/// `detach()` it in a `defer`, so a failing test does not leave a volume mounted.
///
/// Made with `hdiutil create -fs HFS+` (formatted in the image itself) and then `hdiutil attach -plist`,
/// which mounts it before returning and reports where (Ruling R71). The earlier RAM disk
/// (`hdiutil attach -nomount ram://`, then `diskutil eraseVolume`) raced DiskArbitration, which had not
/// always registered the new device yet ("Unable to find disk for /dev/disk7"), and it assumed the
/// volume would be at `/Volumes/<name>`; CI logs show restic then failing to `mkdir /Volumes/<name>`
/// (no volume there, and `/Volumes` belongs to root) or losing files mid-run. Here the mount point is
/// read from hdiutil and checked to be a mount before any test uses it.
final class DiskImage: Sendable {
    let device: String
    let mountPoint: URL
    private let image: URL

    private init(device: String, mountPoint: URL, image: URL) {
        self.device = device
        self.mountPoint = mountPoint
        self.image = image
    }

    static func make(megabytes: Int) async throws -> DiskImage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("disk.dmg")
        let name = "RestoreyTest\(UUID().uuidString.prefix(8))"
        do {
            try await Tool.succeed("/usr/bin/hdiutil", [
                "create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", name, "-layout", "NONE", image.path,
            ])
            let attached = try await Tool.succeed("/usr/bin/hdiutil", [
                "attach", "-plist", "-nobrowse", "-noverify", "-noautoopen", image.path,
            ])
            let (device, mountPoint) = try mounted(fromAttachPlist: attached.stdout)
            let disk = DiskImage(device: device, mountPoint: URL(fileURLWithPath: mountPoint), image: image)
            guard disk.isMounted else {
                await disk.detach()
                throw Tool.Failure(description: "hdiutil attached \(device) at \(mountPoint), which isn't a mount point")
            }
            return disk
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The device and mount point of the one mounted entity in `hdiutil attach -plist`'s output.
    private static func mounted(fromAttachPlist data: Data) throws -> (String, String) {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let entity = entities.first(where: { $0["mount-point"] is String }),
            let device = entity["dev-entry"] as? String, let mountPoint = entity["mount-point"] as? String
        else { throw Tool.Failure(description: "hdiutil attach reported no mounted volume: \(entities)") }
        return (device, mountPoint)
    }

    /// The mount point is the root of a mounted file system (`statfs` names it as its own mount).
    var isMounted: Bool {
        var info = statfs()
        guard statfs(mountPoint.path, &info) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == mountPoint.path
    }

    func detach() async {
        _ = try? await Tool.run("/usr/bin/hdiutil", ["detach", "-force", device])
        try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
    }
}
