import Foundation
import Testing
@testable import RestoreyCore

struct PlanCodingTests {
    private static let s3 = S3Location(
        provider: .b2,
        endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
        bucket: "bucket",
        prefix: "mac"
    )
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(_ repository: Repository, _ origin: RepositoryOrigin) -> Plan {
        Plan.newHotPlan(
            name: "Home", repository: repository, origin: origin, hostLabel: "mac",
            sources: ["/Users/me"], exclusions: ["/Users/me/Library/Caches"], now: Self.now
        )
    }

    @Test func newHotPlanAppliesSpecDefaults() {
        let created = plan(.s3(Self.s3), .created)
        #expect(created.name == "Home")
        #expect(created.hostLabel == "mac")
        #expect(created.sources == ["/Users/me"])
        #expect(created.exclusions == ["/Users/me/Library/Caches"])
        #expect(created.schedule == .interval(seconds: 3600))
        #expect(created.conditions == Conditions(battery: .minimumPercent(20), skipOnConstrainedNetwork: true))
        #expect(created.retention == Retention(hourly: 24, daily: 30, weekly: 52, monthly: 120))
        #expect(created.pruneEnabled)
        #expect(created.forgetCadence == .afterEachBackup)
        #expect(created.packSizeMiB == 64)
        #expect(created.uploadLimitKiB == nil)
        #expect(created.noSuccessAlertDays == 3)
        #expect(!created.hasCheckInURL)
        #expect(created.recoveryKitConfirmedAt == nil)
        #expect(created.createdAt == Self.now)

        let adopted = plan(.s3(Self.s3), .adopted)
        #expect(!adopted.pruneEnabled)
        #expect(adopted.forgetCadence == .daily)
        #expect(adopted.packSizeMiB == nil)
        #expect(adopted.schedule == .interval(seconds: 3600))
        #expect(adopted.noSuccessAlertDays == 3)

        // Pack size is an S3 tuning knob only.
        let raw = plan(.raw(repository: "rest:http://nas/repo", environmentNames: []), .created)
        #expect(raw.pruneEnabled)
        #expect(raw.packSizeMiB == nil)
    }

    @Test func intervalsUnderFiveMinutesAreInvalid() {
        var p = plan(.s3(Self.s3), .created)
        for seconds in [0, -60, 299] {
            p.schedule = .interval(seconds: seconds)
            #expect(p.validationErrors() == [.intervalTooShort(seconds: seconds)])
        }
        p.schedule = .interval(seconds: 300)
        #expect(p.validationErrors().isEmpty)
    }

    @Test func newHotPlansGetDistinctIDs() {
        #expect(plan(.s3(Self.s3), .created).id != plan(.s3(Self.s3), .created).id)
    }

    @Test func resticRepositoryHasNoTrailingSlash() {
        #expect(Self.s3.resticRepository == "s3:https://s3.us-west-004.backblazeb2.com/bucket/mac")
        var messy = Self.s3
        messy.endpoint = URL(string: "https://s3.example.com/")!
        messy.prefix = "/mac/"
        #expect(messy.resticRepository == "s3:https://s3.example.com/bucket/mac")
        messy.prefix = ""
        #expect(messy.resticRepository == "s3:https://s3.example.com/bucket")
    }

    @Test func roundTripsThroughJSON() throws {
        var original = plan(.s3(Self.s3), .created)
        original.uploadLimitKiB = 2048
        original.hasCheckInURL = true
        original.recoveryKitConfirmedAt = Self.now
        original.conditions.battery = .neverOnBattery
        var rawPlan = plan(.raw(repository: "rest:http://nas/repo", environmentNames: ["A", "B"]), .adopted)
        rawPlan.conditions.battery = .minimumPercent(35)

        for sample in [original, rawPlan] {
            let decoded = try VersionedStore<PlanBox>.makeDecoder()
                .decode(Plan.self, from: VersionedStore<PlanBox>.makeEncoder().encode(sample))
            #expect(decoded == sample)
        }
    }

    @Test func subSecondDatesRoundTrip() throws {
        var sample = plan(.s3(Self.s3), .created)
        sample.createdAt = Date(timeIntervalSince1970: 1_762_700_000.123)
        sample.recoveryKitConfirmedAt = Date(timeIntervalSince1970: 1_762_700_001.5)
        let data = try VersionedStore<PlanBox>.makeEncoder().encode(sample)
        #expect(String(decoding: data, as: UTF8.self).contains("2025-11-09T14:53:20.123Z"))
        #expect(try VersionedStore<PlanBox>.makeDecoder().decode(Plan.self, from: data) == sample)
    }

    @Test func datesWithoutFractionalSecondsStillDecode() throws {
        let json = Data(#"{"d":"2027-01-15T08:00:00Z"}"#.utf8)
        struct D: Decodable { var d: Date }
        let decoded = try VersionedStore<PlanBox>.makeDecoder().decode(D.self, from: json)
        #expect(decoded.d == Self.now)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try VersionedStore<PlanBox>.makeEncoder().encode(value), as: UTF8.self)
    }

    @Test func scheduleShapeIsPinned() throws {
        #expect(try json(Schedule.interval(seconds: 3600)) == #"{"seconds":3600,"type":"interval"}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Schedule.self, from: Data(#"{"type":"cron"}"#.utf8))
        }
    }

    @Test func batteryRuleShapeIsPinned() throws {
        #expect(try json(BatteryRule.minimumPercent(20)) == #"{"percent":20,"type":"minimumPercent"}"#)
        #expect(try json(BatteryRule.neverOnBattery) == #"{"type":"neverOnBattery"}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BatteryRule.self, from: Data(#"{"type":"always"}"#.utf8))
        }
    }

    @Test func repositoryShapeIsPinned() throws {
        let s3 = S3Location(provider: .b2, endpoint: URL(string: "https://e.example.com")!, bucket: "b", prefix: "p")
        #expect(try json(Repository.s3(s3))
            == #"{"location":{"bucket":"b","endpoint":"https://e.example.com","prefix":"p","provider":"b2"},"type":"s3"}"#)
        #expect(try json(Repository.raw(repository: "rest:http://nas/r", environmentNames: ["A"]))
            == #"{"environmentNames":["A"],"repository":"rest:http://nas/r","type":"raw"}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Repository.self, from: Data(#"{"type":"sftp"}"#.utf8))
        }
    }

    @Test func datesEncodeAsUTCWithZ() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restorey-plan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VersionedStore<PlanBox>(fileURL: url, currentVersion: 1, migrations: [:])
        try await store.save(PlanBox(plan: plan(.s3(Self.s3), .created)))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"createdAt\" : \"2027-01-15T08:00:00.000Z\""))
        #expect(text.contains(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z/))
    }
}

struct PlanBox: Codable, Sendable, Equatable {
    var plan: Plan
}
