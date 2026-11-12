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
        try roundTrip(HelloReply(
            agentVersion: "0.1.0", agentBuild: "12", executablePath: "/x", draining: false,
            notificationsAuthorised: true, executableFingerprint: "1:2:3:4.5", locationAuthorised: false))
        try roundTrip(HelloReply(
            agentVersion: "0.1.0", agentBuild: "13", executablePath: "/x", draining: false,
            notificationsAuthorised: true, agentRun: UUID()))
    }

    /// An agent from before fix round 3 sends no fingerprint; its reply must still decode (as nil), so the
    /// app can tell it apart and restart it.
    @Test func helloReplyWithoutFingerprintDecodes() throws {
        let json = #"{"agentBuild":"1","agentVersion":"0.1.0","draining":false,"executablePath":"/x"}"#
        let reply = try XPCCoding.decode(HelloReply.self, from: Data(json.utf8))
        #expect(reply.executableFingerprint == nil)
        #expect(reply.agentBuild == "1")
        #expect(reply.locationAuthorised == nil, "an agent older than Task 3 sends no Location field")
        #expect(reply.agentRun == nil, "an agent older than Task 8 sends no run")
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

    @Test func agentStatusRoundTripsNewFields() throws {
        let backup = RunRecord(
            id: UUID(), planID: Self.planID, operation: .backup, trigger: .scheduled,
            startedAt: Self.now, endedAt: Self.now.addingTimeInterval(61), outcome: .unchanged,
            summary: nil, logFile: "2026/11/x.log")
        var plan = Self.plan()
        plan.setupCompletedAt = Self.now
        plan.offMacNoteDismissed = true
        let size = RepositorySize(bytes: 9_876_543_210, measuredAt: Self.now)
        let status = AgentStatus(
            plans: [PlanSetupState.unfinished, .needsNewKit, .complete].map {
                PlanStatus(plan: plan, phase: .idle, lastRecord: nil, nextRunAt: nil, alerts: [],
                           lastBackup: backup, repositorySize: size, setupState: $0)
            },
            configError: nil, fdaMissing: false, generatedAt: Self.now, agentRun: UUID(), sequence: 3,
            network: NetworkSettings(uploadLimitKiB: 2048, skipOnConstrainedNetwork: false, skippedWiFiNames: ["Café"]))
        try roundTrip(status)
        try roundTrip(AgentStatus(plans: [], configError: "x", fdaMissing: nil, generatedAt: Self.now))
    }

    @Test func newShapesArePinned() throws {
        #expect(try json(NetworkSettings.defaults) == #"{"skipOnConstrainedNetwork":true,"skippedWiFiNames":[]}"#)
        #expect(try json(RepositorySize(bytes: 42, measuredAt: Date(timeIntervalSince1970: 1_800_000_000)))
            == #"{"bytes":42,"measuredAt":"2027-01-15T08:00:00.000Z"}"#)
        #expect(try json([PlanSetupState.unfinished, .needsNewKit, .complete])
            == #"["unfinished","needsNewKit","complete"]"#)
    }

    /// A status as a v0.1 build 11 agent sent it: plans with `skipOnConstrainedNetwork` in their conditions
    /// and none of the new keys. It decodes, with the new fields nil or derived from the plan.
    @Test func aBuild11StatusDecodes() throws {
        func plan(id: String, confirmed: String?) -> String {
            #"{"conditions":{"battery":{"percent":20,"type":"minimumPercent"},"skipOnConstrainedNetwork":true},"#
                + #""createdAt":"2027-01-15T08:00:00.123Z","exclusions":[],"fileTypeExclusions":["dmg"],"#
                + #""forgetCadence":"afterEachBackup","hasCheckInURL":false,"hostLabel":"mac","id":"\#(id)","#
                + #""name":"Home","noSuccessAlertDays":3,"oneFileSystem":true,"origin":"created","packSizeMiB":64,"#
                + #""pruneEnabled":true,"#
                + (confirmed.map { #""recoveryKitConfirmedAt":"\#($0)","# } ?? "")
                + #""repository":{"location":{"bucket":"bucket","endpoint":"https://s3.us-west-004.backblazeb2.com","#
                + #""prefix":"mac","provider":"b2"},"type":"s3"},"#
                + #""retention":{"daily":30,"hourly":24,"monthly":120,"weekly":52},"#
                + #""schedule":{"seconds":3600,"type":"interval"},"sources":["/Users/me"]}"#
        }
        let unconfirmed = plan(id: "6F1C2E1A-0000-4000-8000-000000000001", confirmed: nil)
        let confirmed = plan(id: "6F1C2E1A-0000-4000-8000-000000000002", confirmed: "2027-01-15T09:00:00.000Z")
        let json = #"{"agentRun":"6F1C2E1A-0000-4000-8000-0000000000AA","fdaMissing":false,"#
            + #""generatedAt":"2027-01-15T10:00:00.000Z","plans":["#
            + #"{"alerts":[],"nextRunAt":"2027-01-15T11:00:00.000Z","phase":{"type":"idle"},"plan":\#(unconfirmed)},"#
            + #"{"alerts":[],"phase":{"type":"idle"},"plan":\#(confirmed)}"#
            + #"],"sequence":4}"#
        let status = try XPCCoding.decode(AgentStatus.self, from: Data(json.utf8))
        #expect(status.network == nil)
        #expect(status.plans.count == 2)
        for plan in status.plans {
            #expect(plan.plan.setupCompletedAt == nil)
            #expect(!plan.plan.offMacNoteDismissed)
            #expect(plan.lastBackup == nil)
            #expect(plan.repositorySize == nil)
        }
        #expect(status.plans[0].setupState == .unfinished)
        #expect(status.plans[1].setupState == .complete)
    }

    // MARK: Ordering statuses (final review M1)

    private func status(at seconds: TimeInterval, run: UUID?, sequence: UInt64?) -> AgentStatus {
        AgentStatus(plans: [], configError: nil, fdaMissing: nil, generatedAt: Self.now.addingTimeInterval(seconds),
                    agentRun: run, sequence: sequence)
    }

    @Test func aLaterStatusSupersedesEvenWhenTheClockWentBackwards() {
        let run = UUID()
        let shown = status(at: 0, run: run, sequence: 7)
        // Built after `shown` by the same agent, with the clock moved back 5 hours.
        #expect(status(at: -5 * 3600, run: run, sequence: 8).supersedes(shown))
        #expect(!status(at: 60, run: run, sequence: 6).supersedes(shown), "an older reply arriving late")
        #expect(status(at: 0, run: run, sequence: 7).supersedes(shown))
        #expect(status(at: 0, run: run, sequence: 1).supersedes(nil))
    }

    @Test func aRestartedAgentsStatusAlwaysSupersedes() {
        let shown = status(at: 0, run: UUID(), sequence: 900)
        #expect(status(at: -60, run: UUID(), sequence: 1).supersedes(shown))
    }

    @Test func anOlderAgentWithoutSequenceNumbersIsOrderedByDate() throws {
        let shown = status(at: 0, run: nil, sequence: nil)
        #expect(status(at: 1, run: nil, sequence: nil).supersedes(shown))
        #expect(!status(at: -1, run: nil, sequence: nil).supersedes(shown))
        // And its JSON, without the new keys, still decodes.
        let old = #"{"plans":[],"generatedAt":"2027-01-15T08:00:00.000Z"}"#
        let decoded = try XPCCoding.decode(AgentStatus.self, from: Data(old.utf8))
        #expect(decoded.sequence == nil && decoded.agentRun == nil)
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
        try roundTrip(LocationPermissionReply(authorised: true, status: "authorisedAlways"))
        #expect(try json(LocationPermissionReply(authorised: false, status: "denied"))
            == #"{"authorised":false,"status":"denied"}"#)
    }

    @Test func repositoryProbeRoundTripsAndItsShapeIsPinned() throws {
        let report = AdoptReport(hosts: ["other"], latestPathsForHost: [], snapshotCount: 2)
        try roundTrip(RepositoryProbe(state: .empty))
        try roundTrip(RepositoryProbe(state: .existing(report)))
        #expect(try json(RepositoryProbe(state: .empty)) == #"{"state":{"type":"empty"}}"#)
        #expect(try json(RepositoryProbe(state: .existing(report)))
            == #"{"state":{"report":{"hosts":["other"],"latestPathsForHost":[],"snapshotCount":2},"type":"existing"}}"#)
        #expect(throws: DecodingError.self) {
            try XPCCoding.decode(RepositoryProbe.self, from: Data(#"{"state":{"type":"locked"}}"#.utf8))
        }
    }

    @Test func recoveryKitSecretsRoundTrip() throws {
        try roundTrip(RecoveryKitSecrets(plan: Self.plan(), secrets: [
            SecretEntry(key: .repositoryPassword(Self.planID), value: "pa ss\"wörd\n"),
            SecretEntry(key: .checkInURL(Self.planID), value: "https://hc-ping.com/x"),
        ]))
    }

    /// `recoveryKit`'s reply carries every secret of a plan, so it must never print one either.
    @Test func recoveryKitSecretsDescriptionsAreRedacted() {
        let secret = "hunter2-very-secret"
        let kit = RecoveryKitSecrets(plan: Self.plan(), secrets: [
            SecretEntry(key: .repositoryPassword(Self.planID), value: secret),
            SecretEntry(key: .checkInURL(Self.planID), value: "https://hc-ping.com/\(secret)"),
        ])
        var dumped = ""
        dump(kit, to: &dumped)
        for text in [String(describing: kit), String(reflecting: kit), "\(kit)", dumped] {
            #expect(!text.contains("hunter2"), "leaked in: \(text)")
        }
        #expect(String(describing: kit).contains("repository-password"))
        #expect(String(describing: kit).contains(Self.planID.uuidString))
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
