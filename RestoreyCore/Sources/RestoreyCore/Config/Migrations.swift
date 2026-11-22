import Foundation

/// Schema history for `config.json`. `VersionedStore` runs `migrations[n]` to take a payload from
/// version `n` to `n + 1`, working on the decoded dictionary so old shapes never need old Swift types.
public enum ConfigMigrations {
    public static let currentVersion = 5

    public static let migrations: [Int: @Sendable (inout [String: Any]) throws -> Void] = [
        1: addFileTypeExclusionsAndOneFileSystem,
        2: moveNetworkRulesToConfig,
        3: addExclusionDefaultsRevision,
        4: convertUploadLimits,
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

    /// 2 → 3 (Ruling P2-6, P2-3): the constrained-network rule becomes Mac-wide. The payload gets `network`
    /// (no Mac-wide upload limit, no Wi-Fi names, and `skipOnConstrainedNetwork` true if any plan had it
    /// on, as is the default, or there are no plans; false only when every plan had turned it off), and each plan's
    /// `conditions.skipOnConstrainedNetwork` is removed. Each plan also gets `setupCompletedAt`, set to its
    /// `recoveryKitConfirmedAt` (a plan whose kit was confirmed finished setup; one without stays
    /// unfinished), and `offMacNoteDismissed = false`. Values a plan or the payload already has are kept.
    @Sendable public static func moveNetworkRulesToConfig(_ payload: inout [String: Any]) throws {
        var list: [[String: Any]] = []
        if let plans = payload["plans"] {
            guard let typed = plans as? [[String: Any]] else { throw MigrationError.notAPlanList }
            list = typed
        }
        var skips: [Bool] = []
        for index in list.indices {
            if var conditions = list[index]["conditions"] as? [String: Any] {
                // A plan without the key had the default, on.
                skips.append(conditions["skipOnConstrainedNetwork"] as? Bool ?? true)
                conditions["skipOnConstrainedNetwork"] = nil
                list[index]["conditions"] = conditions
            }
            if list[index]["setupCompletedAt"] == nil, let confirmed = list[index]["recoveryKitConfirmedAt"] {
                list[index]["setupCompletedAt"] = confirmed
            }
            if list[index]["offMacNoteDismissed"] == nil { list[index]["offMacNoteDismissed"] = false }
        }
        if payload["plans"] != nil { payload["plans"] = list }
        if payload["network"] == nil {
            payload["network"] = [
                "skipOnConstrainedNetwork": skips.isEmpty || skips.contains(true),
                "skippedWiFiNames": [String](),
            ] as [String: Any]
        }
    }

    /// 3 → 4 (owner, 20 Nov 2026): every plan gets `exclusionDefaultsRevision = 1`, the default folder list it was made
    /// from (the CoreSpeech caches, added on 17 Nov 2026, are the only default added since schema 3). The agent adds
    /// later defaults once it has loaded the file (`AgentState.addNewDefaultExclusions`): it knows the home folder,
    /// which this migration doesn't. Folder `exclusions` are left exactly as stored. A plan that somehow already has
    /// the key keeps its value.
    @Sendable public static func addExclusionDefaultsRevision(_ payload: inout [String: Any]) throws {
        guard let plans = payload["plans"] else { return }
        guard var list = plans as? [[String: Any]] else { throw MigrationError.notAPlanList }
        for index in list.indices where list[index]["exclusionDefaultsRevision"] == nil {
            list[index]["exclusionDefaultsRevision"] = 1
        }
        payload["plans"] = list
    }

    /// 4 → 5 (upload limit redesign): the Mac-wide `network.uploadLimitKiB: n` becomes
    /// `network.uploadLimit = {"kind":"rate","kiB":n,"unit":"MB"}` (an old limit was entered in megabytes), or
    /// `{"kind":"none"}` when there was none, and `uploadLimitKiB` is removed. No `limitWindow` is added. Every plan
    /// gets `uploadLimitUnit: "MB"` when it lacks one; its own `uploadLimitKiB` is untouched. A payload without
    /// `network` stays without one, and an `uploadLimit` already there is kept.
    @Sendable public static func convertUploadLimits(_ payload: inout [String: Any]) throws {
        if let plans = payload["plans"] {
            guard var list = plans as? [[String: Any]] else { throw MigrationError.notAPlanList }
            for index in list.indices where list[index]["uploadLimitUnit"] == nil {
                list[index]["uploadLimitUnit"] = "MB"
            }
            payload["plans"] = list
        }
        guard var network = payload["network"] as? [String: Any] else { return }
        if network["uploadLimit"] == nil {
            if let kiB = network["uploadLimitKiB"] as? Int {
                network["uploadLimit"] = ["kind": "rate", "kiB": kiB, "unit": "MB"] as [String: Any]
            } else {
                network["uploadLimit"] = ["kind": "none"]
            }
        }
        network["uploadLimitKiB"] = nil
        payload["network"] = network
    }
}
