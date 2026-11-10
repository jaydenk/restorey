import Foundation
import Testing
@testable import RestoreyCore

struct MessagesTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000.123)
    private static let planID = UUID(uuidString: "6F1C2E1A-0000-4000-8000-000000000001")!

    private static func plan() -> Plan {
        var plan = Plan.newHotPlan(
            name: "Home",
            repository: .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "bucket", prefix: "mac")),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        plan.id = planID
        return plan
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try XPCCoding.encode(value)
        #expect(try XPCCoding.decode(T.self, from: data) == value)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try XPCCoding.encode(value), as: UTF8.self)
    }

    @Test func helloRoundTrips() throws {
        try roundTrip(HelloRequest(appVersion: "0.1.0", appBuild: "7"))
        try roundTrip(HelloReply(
            agentVersion: "0.1.0", agentBuild: "7",
            executablePath: "/Applications/Restorey.app/Contents/Helpers/RestoreyAgent.app/Contents/MacOS/RestoreyAgent",
            draining: true, notificationsAuthorised: nil))
        try roundTrip(HelloReply(
            agentVersion: "0.1.0", agentBuild: "8", executablePath: "/x", draining: false,
            notificationsAuthorised: false, executableFingerprint: "16777234:42:59216:1.5"))
    }

    /// An agent from before fix round 3 sends no fingerprint; its reply must still decode (as nil), so the
    /// app can tell it apart and restart it.
    @Test func helloReplyWithoutFingerprintDecodes() throws {
        let json = #"{"agentBuild":"1","agentVersion":"0.1.0","draining":false,"executablePath":"/x"}"#
        let reply = try XPCCoding.decode(HelloReply.self, from: Data(json.utf8))
        #expect(reply.executableFingerprint == nil)
        #expect(reply.agentBuild == "1")
    }

    @Test func statusRoundTripsWithEveryPhase() throws {
        let record = RunRecord(
            id: UUID(), planID: Self.planID, operation: .backup, trigger: .scheduled,
            startedAt: Self.now, endedAt: Self.now.addingTimeInterval(61), outcome: .success(snapshotID: "abc"),
            summary: BackupSummary(filesNew: 2, snapshotID: "abc"), logFile: "2026/11/x.log")
        let phases: [PlanPhase] = [
            .idle,
            .running(nil, retrying: nil),
            .running(
                BackupStatus(percentDone: 0.5, totalFiles: 10, filesDone: 5, totalBytes: 100, bytesDone: 50,
                             secondsRemaining: 30, errorCount: 1, currentFiles: ["/Users/me/a"]),
                retrying: "Load(<data/abc>, 0, 0) returned error, retrying after 1s: connection refused"),
            .paused(until: Self.now.addingTimeInterval(3600)),
            .stopped(reason: "The repository password is wrong"),
            .skipped(.batteryBelow(20)),
        ]
        let status = AgentStatus(
            plans: phases.map {
                PlanStatus(plan: Self.plan(), phase: $0, lastRecord: record, nextRunAt: Self.now,
                           alerts: [.backupFailed, .noRecentSuccess])
            },
            configError: nil, fdaMissing: true, generatedAt: Self.now)
        try roundTrip(status)
        try roundTrip(AgentStatus(
            plans: [], configError: "config.json was written by a newer Restorey", fdaMissing: nil,
            generatedAt: Self.now))
    }

    @Test func phaseShapeIsPinned() throws {
        #expect(try json(PlanPhase.idle) == #"{"type":"idle"}"#)
        #expect(try json(PlanPhase.running(nil, retrying: nil)) == #"{"type":"running"}"#)
        #expect(try json(PlanPhase.running(BackupStatus(percentDone: 0.25), retrying: "retrying"))
            == #"{"progress":{"bytesDone":0,"currentFiles":[],"errorCount":0,"filesDone":0,"percentDone":0.25,"totalBytes":0,"totalFiles":0},"retrying":"retrying","type":"running"}"#)
        #expect(try json(PlanPhase.paused(until: Date(timeIntervalSince1970: 1_800_000_000)))
            == #"{"type":"paused","until":"2027-01-15T08:00:00.000Z"}"#)
        #expect(try json(PlanPhase.stopped(reason: "r")) == #"{"reason":"r","type":"stopped"}"#)
        #expect(try json(PlanPhase.skipped(.onBattery)) == #"{"reason":{"type":"onBattery"},"type":"skipped"}"#)
        #expect(throws: DecodingError.self) {
            try XPCCoding.decode(PlanPhase.self, from: Data(#"{"type":"sleeping"}"#.utf8))
        }
    }

    @Test func secretKeyShapeIsPinned() throws {
        let id = "6F1C2E1A-0000-4000-8000-000000000001"
        #expect(try json(SecretKey.repositoryPassword(Self.planID))
            == #"{"planID":"\#(id)","type":"repositoryPassword"}"#)
        #expect(try json(SecretKey.s3AccessKeyID(Self.planID)) == #"{"planID":"\#(id)","type":"s3AccessKeyID"}"#)
        #expect(try json(SecretKey.s3SecretAccessKey(Self.planID))
            == #"{"planID":"\#(id)","type":"s3SecretAccessKey"}"#)
        #expect(try json(SecretKey.environment(Self.planID, name: "RESTIC_REST_PASSWORD"))
            == #"{"name":"RESTIC_REST_PASSWORD","planID":"\#(id)","type":"environment"}"#)
        #expect(try json(SecretKey.checkInURL(Self.planID)) == #"{"planID":"\#(id)","type":"checkInURL"}"#)
        #expect(throws: DecodingError.self) {
            try XPCCoding.decode(SecretKey.self, from: Data(#"{"type":"sshKey","planID":"\#(id)"}"#.utf8))
        }
    }

    @Test func savePlanRequestRoundTrips() throws {
        let keys: [SecretKey] = [
            .repositoryPassword(Self.planID), .s3AccessKeyID(Self.planID), .s3SecretAccessKey(Self.planID),
            .environment(Self.planID, name: "B2_ACCOUNT_KEY"), .checkInURL(Self.planID),
        ]
        try roundTrip(SavePlanRequest(
            plan: Self.plan(),
            secrets: keys.map { SecretEntry(key: $0, value: "pa ss\"wörd\n") }))
    }

    @Test func otherRepliesRoundTrip() throws {
        try roundTrip(AdoptReport(hosts: ["mac", "nas"], latestPathsForHost: ["/Users/me"], snapshotCount: 12))
        try roundTrip(DrainReply(drained: true))
        #expect(try json(DrainReply(drained: true)) == #"{"drained":true}"#)
        try roundTrip(NotificationPermissionReply(granted: false))
    }

    @Test func descriptionsNeverContainSecretValues() {
        let secret = "hunter2-very-secret"
        let entry = SecretEntry(key: .repositoryPassword(Self.planID), value: secret)
        let request = SavePlanRequest(plan: Self.plan(), secrets: [
            entry, SecretEntry(key: .checkInURL(Self.planID), value: "https://hc-ping.com/\(secret)"),
        ])
        var dumped = ""
        dump(request, to: &dumped)
        for text in [
            String(describing: entry), String(reflecting: entry), "\(entry)",
            String(describing: request), String(reflecting: request), "\(request)",
            String(describing: [entry]), String(reflecting: [entry]), dumped,
        ] {
            #expect(!text.contains(secret), "leaked in: \(text)")
            #expect(!text.contains("hunter2"))
        }
        // The key is still named, so a log line says which secret was involved.
        #expect(String(describing: entry).contains("repository-password"))
        #expect(String(describing: request).contains(Self.planID.uuidString))
    }
}
