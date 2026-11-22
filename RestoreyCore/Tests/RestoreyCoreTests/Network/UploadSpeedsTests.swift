import Foundation
import Testing
@testable import RestoreyCore

struct UploadSpeedsTests {
    @Test func networkKeysRoundTripAsDictionaryKeys() throws {
        let measured = UploadSpeedMeasurement(bitsPerSecond: 40_000_000, bytesSent: 1_000, measuredAt: Date(timeIntervalSince1970: 1_800_000_000))
        let file = UploadSpeedsFile(records: [
            .wiFi(name: "Kerr Home"): UploadSpeedRecord(latest: measured, lastFailure: nil),
            .wiFiUnknown: UploadSpeedRecord(latest: nil, lastFailure: SpeedTestFailure(at: measured.measuredAt, reason: "The upload speed test didn’t finish in time")),
            .ethernet: UploadSpeedRecord(latest: measured, lastFailure: nil),
            .other: UploadSpeedRecord(latest: measured, lastFailure: nil),
        ])
        let data = try JSONEncoder().encode(file)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(json["records"] as? [String: Any], "an object keyed by string, not an array of pairs")
        #expect(Set(records.keys) == ["wifi:Kerr Home", "wifi?", "ethernet", "other"])
        #expect(try JSONDecoder().decode(UploadSpeedsFile.self, from: data) == file)
    }

    @Test func wiFiKeysMatchIgnoringCaseAndForm() {
        #expect(NetworkKey.wiFi(name: "Caf\u{E9}") == NetworkKey.wiFi(name: "Cafe\u{301}"))
        #expect(NetworkKey.wiFi(name: "kerr home") == NetworkKey.wiFi(name: "Kerr Home"))
        #expect(NetworkKey.wiFi(name: "  Kerr Home ") == NetworkKey.wiFi(name: "Kerr Home"))
        #expect(NetworkKey.wiFi(name: "Cafe") != NetworkKey.wiFi(name: "Caf\u{E9}"), "accents still differ, as for the skip list")
        #expect(NetworkKey.wiFi(name: "A") != NetworkKey.wiFiUnknown)
        var records: [NetworkKey: Int] = [.wiFi(name: "Kerr Home"): 1]
        records[.wiFi(name: "KERR HOME")] = 2
        #expect(records.count == 1)
    }

    @Test func displayNames() {
        #expect(NetworkKey.wiFi(name: " Kerr Home ").displayName == "Kerr Home")
        #expect(NetworkKey.wiFiUnknown.displayName == "Wi-Fi (name unknown)")
        #expect(NetworkKey.ethernet.displayName == "Ethernet")
        #expect(NetworkKey.other.displayName == "this network")
    }

    @Test func aWiFiNameThatLooksLikeAnotherFormStaysAWiFiName() throws {
        let keys: [NetworkKey] = [.wiFi(name: "ethernet"), .wiFi(name: ""), .wiFi(name: "wifi?")]
        for key in keys {
            let data = try JSONEncoder().encode(UploadSpeedsFile(records: [key: UploadSpeedRecord()]))
            #expect(try JSONDecoder().decode(UploadSpeedsFile.self, from: data).records.keys.first == key)
        }
    }

    @Test func theStoreSavesAndLoadsAtSchemaOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-speeds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadSpeedsFile.store(in: directory)
        #expect(try await store.load() == nil)
        let file = UploadSpeedsFile(records: [
            .ethernet: UploadSpeedRecord(latest: UploadSpeedMeasurement(bitsPerSecond: 5e6, bytesSent: nil, measuredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        ])
        try await store.save(file)
        #expect(try await store.load() == file)
        let text = try String(contentsOf: directory.appendingPathComponent("upload-speeds.json"), encoding: .utf8)
        #expect(text.contains("\"schemaVersion\" : 1"))
    }
}
