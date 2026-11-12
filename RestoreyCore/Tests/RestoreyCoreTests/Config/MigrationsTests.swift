import Foundation
import Testing
@testable import RestoreyCore

/// `config.json` schema 2 → 3 (Ruling P2-6), on the decoded dictionary as `VersionedStore` runs it.
struct MigrationsTests {
    private static let confirmedAt = "2027-01-15T08:00:00.000Z"

    /// A plan as schema 2 stored it, cut down to the keys the migration reads or writes.
    private static func v2Plan(skip: Bool, confirmedAt: String?) -> [String: Any] {
        var plan: [String: Any] = [
            "name": "Home",
            "conditions": ["battery": ["type": "minimumPercent", "percent": 20], "skipOnConstrainedNetwork": skip],
        ]
        if let confirmedAt { plan["recoveryKitConfirmedAt"] = confirmedAt }
        return plan
    }

    private static func migrate(_ plans: [[String: Any]]?) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        if let plans { payload["plans"] = plans }
        try #require(ConfigMigrations.migrations[2] != nil)
        try ConfigMigrations.migrations[2]?(&payload)
        return payload
    }

    private static func network(_ payload: [String: Any]) throws -> NetworkSettings {
        let raw = try #require(payload["network"])
        return try XPCCoding.decode(NetworkSettings.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    @Test func currentVersionIsThree() {
        #expect(ConfigMigrations.currentVersion == 3)
    }

    @Test func migratesV2PlansToV3() throws {
        let payload = try Self.migrate([
            Self.v2Plan(skip: true, confirmedAt: Self.confirmedAt),
            Self.v2Plan(skip: false, confirmedAt: nil),
        ])
        let plans = try #require(payload["plans"] as? [[String: Any]])
        #expect(plans.count == 2)
        for plan in plans {
            let conditions = try #require(plan["conditions"] as? [String: Any])
            #expect(conditions["skipOnConstrainedNetwork"] == nil)
            #expect(conditions["battery"] != nil, "the battery rule stays with the plan")
            #expect(plan["offMacNoteDismissed"] as? Bool == false)
        }
        // A confirmed plan finished setup when its kit was confirmed; an unconfirmed one hasn't finished.
        #expect(plans[0]["setupCompletedAt"] as? String == Self.confirmedAt)
        #expect(plans[1]["setupCompletedAt"] == nil)
        #expect(try Self.network(payload)
            == NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: true, skippedWiFiNames: []))
    }

    @Test func migratesV2WithAllPlansOffToSkipFalse() throws {
        let off = try Self.migrate([Self.v2Plan(skip: false, confirmedAt: nil), Self.v2Plan(skip: false, confirmedAt: nil)])
        #expect(try Self.network(off).skipOnConstrainedNetwork == false)

        // No plans (or none yet): the default.
        #expect(try Self.network(try Self.migrate([])) == .defaults)
        #expect(try Self.network(try Self.migrate(nil)) == .defaults)
    }

    @Test func networkDefaultsArePinned() {
        #expect(NetworkSettings.defaults
            == NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: true, skippedWiFiNames: []))
    }

    /// Values a plan or payload somehow already has are kept, as migration 1 does.
    @Test func existingValuesAreKept() throws {
        var plan = Self.v2Plan(skip: false, confirmedAt: Self.confirmedAt)
        plan["setupCompletedAt"] = "2026-01-01T00:00:00.000Z"
        plan["offMacNoteDismissed"] = true
        var payload: [String: Any] = [
            "plans": [plan],
            "network": ["skipOnConstrainedNetwork": true, "skippedWiFiNames": ["Café"], "uploadLimitKiB": 500],
        ]
        try ConfigMigrations.moveNetworkRulesToConfig(&payload)
        let migrated = try #require((payload["plans"] as? [[String: Any]])?.first)
        #expect(migrated["setupCompletedAt"] as? String == "2026-01-01T00:00:00.000Z")
        #expect(migrated["offMacNoteDismissed"] as? Bool == true)
        #expect(try Self.network(payload)
            == NetworkSettings(uploadLimitKiB: 500, skipOnConstrainedNetwork: true, skippedWiFiNames: ["Café"]))
    }

    @Test func aPlanListThatIsntOneIsRefused() {
        var payload: [String: Any] = ["plans": "nope"]
        #expect(throws: ConfigMigrations.MigrationError.notAPlanList) {
            try ConfigMigrations.moveNetworkRulesToConfig(&payload)
        }
    }
}
