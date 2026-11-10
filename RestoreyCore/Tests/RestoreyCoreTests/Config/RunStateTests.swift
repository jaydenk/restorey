import Foundation
import Testing
@testable import RestoreyCore

struct RunStateTests {
    private let planID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let recordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    /// Whole milliseconds, so values survive the store's date format exactly.
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func makeRecord() -> RunRecord {
        RunRecord(
            id: recordID, planID: planID, operation: .backup, trigger: .catchUp,
            startedAt: date(1_800_000_000.123), endedAt: date(1_800_000_060.5),
            outcome: .success(snapshotID: "abc"),
            summary: BackupSummary(
                filesNew: 1, filesChanged: 2, filesUnmodified: 3, dataAdded: 4, dataAddedPacked: 5,
                totalFilesProcessed: 6, totalBytesProcessed: 7, totalDuration: 1.5,
                backupStart: date(1_800_000_000.25), backupEnd: date(1_800_000_001.75), snapshotID: "abc"
            ),
            logFile: "plan/run.log"
        )
    }

    private func makeState() -> RunState {
        var history = PlanRunHistory()
        history.lastSuccessAt = date(1_800_000_060.5)
        history.lastAttemptAt = date(1_800_000_060.5)
        history.lastSnapshotAt = date(1_800_000_001.75)
        history.lastForgetAt = date(1_800_000_070)
        history.lastPruneAt = date(1_800_000_080)
        history.lastCheckAt = date(1_800_000_090)
        history.runningRecordID = recordID
        history.recent = [makeRecord()]
        history.activeAlerts = [
            .backupFailed: AlertNotificationState(raisedAt: date(1_800_000_100), lastNotifiedAt: nil, count: 1),
            .noRecentSuccess: AlertNotificationState(
                raisedAt: date(1_800_000_200), lastNotifiedAt: date(1_800_000_300), count: 2),
        ]
        history.stoppedReason = "Repository password rejected."
        history.pausedUntil = date(1_800_003_600)
        return RunState(plans: [planID: history])
    }

    @Test func runStateRoundTripsThroughVersionedStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-runstate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = VersionedStore<RunState>(
            fileURL: dir.appendingPathComponent("state.json"), currentVersion: 1, migrations: [:])

        #expect(try await store.load() == nil)
        let state = makeState()
        try await store.save(state)
        let loaded = try #require(try await store.load())
        #expect(loaded == state)
        #expect(loaded.plans[planID]?.recent.first?.summary?.snapshotID == "abc")
    }

    @Test func stateFileIsAnObjectKeyedByPlanIDWithRawAlertKeys() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-runstate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let store = VersionedStore<RunState>(fileURL: file, currentVersion: 1, migrations: [:])
        try await store.save(makeState())

        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 1)
        let plans = try #require((root["payload"] as? [String: Any])?["plans"] as? [String: Any])
        let history = try #require(plans[planID.uuidString] as? [String: Any])
        let alerts = try #require(history["activeAlerts"] as? [String: Any])
        #expect(Set(alerts.keys) == ["backupFailed", "noRecentSuccess"])
        #expect(history["lastSuccessAt"] as? String == "2027-01-15T08:01:00.500Z")
    }

    @Test func activeAlertsGoldenJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var history = PlanRunHistory()
        history.activeAlerts = [
            .fullDiskAccessMissing: AlertNotificationState(raisedAt: Date(timeIntervalSince1970: 1), lastNotifiedAt: nil, count: 3),
        ]
        let text = String(decoding: try encoder.encode(history), as: UTF8.self)
        #expect(text == #"{"activeAlerts":{"fullDiskAccessMissing":{"count":3,"raisedAt":1000}},"recent":[]}"#)

        let decoded = try JSONDecoder().decode(PlanRunHistory.self, from: Data(#"{"activeAlerts":{"noRecentSuccess":{"count":1,"raisedAt":1.5}},"recent":[]}"#.utf8))
        #expect(decoded.activeAlerts.keys.contains(.noRecentSuccess))
    }

    @Test func everyAlertConditionKeyRoundTrips() throws {
        let all: [AlertCondition] = [
            .backupFailed, .checkFailed, .configurationError, .fullDiskAccessMissing, .noRecentSuccess, .notificationsOff,
        ]
        var history = PlanRunHistory()
        for c in all { history.activeAlerts[c] = AlertNotificationState(raisedAt: Date(timeIntervalSince1970: 0), lastNotifiedAt: nil, count: 1) }
        let data = try JSONEncoder().encode(history)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set((object["activeAlerts"] as? [String: Any])?.keys.map { $0 } ?? []) == Set(all.map(\.rawValue)))
        #expect(try JSONDecoder().decode(PlanRunHistory.self, from: data) == history)
    }

    @Test func unknownAlertKeysAreRefused() {
        let text = #"{"activeAlerts":{"bogus":{"count":1,"raisedAt":1}},"recent":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PlanRunHistory.self, from: Data(text.utf8)) }
    }

    @Test func emptyHistoryEncodesOnlyRequiredKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(PlanRunHistory()), as: UTF8.self) == #"{"activeAlerts":{},"recent":[]}"#)
        #expect(try JSONDecoder().decode(PlanRunHistory.self, from: Data("{}".utf8)) == PlanRunHistory())
    }

    @Test func runRecordJSONIsExplicit() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let record = RunRecord(
            id: recordID, planID: planID, operation: .forget(dryRun: true), trigger: .retry,
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            outcome: .warning(unreadable: 2), summary: nil, logFile: "l.log")
        let text = String(decoding: try encoder.encode(record), as: UTF8.self)
        #expect(text == #"{"endedAt":2000,"id":"00000000-0000-0000-0000-0000000000B2","logFile":"l.log","operation":{"dryRun":true,"type":"forget"},"outcome":{"type":"warning","unreadable":2},"planID":"00000000-0000-0000-0000-0000000000A1","startedAt":1000,"trigger":"retry"}"#)
    }

    @Test func backupSummaryJSONUsesResticFieldNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let s = BackupSummary(filesNew: 1, totalDuration: 2, backupStart: Date(timeIntervalSince1970: 1), snapshotID: "x")
        #expect(String(decoding: try encoder.encode(s), as: UTF8.self) ==
            #"{"backup_start":1000,"data_added":0,"data_added_packed":0,"files_changed":0,"files_new":1,"files_unmodified":0,"snapshot_id":"x","total_bytes_processed":0,"total_duration":2,"total_files_processed":0}"#)
    }

    @Test func recordPutsNewestFirstAndCapsAtFifty() {
        var history = PlanRunHistory()
        var ids: [UUID] = []
        for i in 0..<60 {
            var r = makeRecord()
            r.id = UUID()
            r.startedAt = date(Double(i))
            ids.append(r.id)
            history.record(r)
        }
        #expect(PlanRunHistory.recentLimit == 50)
        #expect(history.recent.count == 50)
        #expect(history.recent.first?.id == ids[59])
        #expect(history.recent.last?.id == ids[10])
    }
}
