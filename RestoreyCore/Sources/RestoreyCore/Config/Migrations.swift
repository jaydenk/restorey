import Foundation

/// Schema history for `config.json`. `VersionedStore` runs `migrations[n]` to take a payload from
/// version `n` to `n + 1`, working on the decoded dictionary so old shapes never need old Swift types.
public enum ConfigMigrations {
    public static let currentVersion = 2

    public static let migrations: [Int: @Sendable (inout [String: Any]) throws -> Void] = [
        1: addFileTypeExclusionsAndOneFileSystem,
    ]

    public enum MigrationError: Error, Equatable {
        case notAPlanList
    }

    /// The file types schema 2 introduced, as `DefaultExclusions.fileTypes` was on 11 Nov 2026. Frozen: the
    /// 1 → 2 migration must give every old plan exactly this list, whatever the default becomes later.
    static let schema2FileTypes: [String] = [
        "dmg", "iso", "sparseimage",
        "vmdk", "vhd", "vhdx", "vdi", "qcow2", "hdd", "hds", "pvm", "pvs", "pvi", "pva", "fdd", "vmc",
        "vmx", "vmxf", "vmsn", "vmsd", "vmem", "nvram", "mem", "vsv",
    ]

    /// 1 → 2 (Ruling R64): every plan gets the schema-2 file-type exclusions (`schema2FileTypes`) and
    /// `oneFileSystem = true`. Its folder `exclusions` are the person's and are left exactly as stored. A
    /// plan that somehow already has either key keeps its value.
    @Sendable public static func addFileTypeExclusionsAndOneFileSystem(_ payload: inout [String: Any]) throws {
        guard let plans = payload["plans"] else { return }
        guard var list = plans as? [[String: Any]] else { throw MigrationError.notAPlanList }
        for index in list.indices {
            if list[index]["fileTypeExclusions"] == nil {
                list[index]["fileTypeExclusions"] = schema2FileTypes
            }
            if list[index]["oneFileSystem"] == nil { list[index]["oneFileSystem"] = true }
        }
        payload["plans"] = list
    }
}
