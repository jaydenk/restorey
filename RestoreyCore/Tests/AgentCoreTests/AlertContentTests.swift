import Foundation
import Testing
@testable import AgentCore
import RestoreyCore

struct AlertContentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(created: Date? = nil) -> Plan {
        Plan.newHotPlan(
            name: "Home", repository: .raw(repository: "/Volumes/Backup/restic", environmentNames: []),
            origin: .created, hostLabel: "mac", sources: ["/Users/me/Documents"], exclusions: [],
            now: created ?? now)
    }

    private func record(_ operation: ResticOperation, _ outcome: RunOutcome, planID: UUID) -> RunRecord {
        RunRecord(
            id: UUID(), planID: planID, operation: operation, trigger: .scheduled, startedAt: now, endedAt: now,
            outcome: outcome, summary: nil, logFile: "")
    }

    private func content(_ condition: AlertCondition, plan: Plan, history: PlanRunHistory = PlanRunHistory()) -> AlertContent? {
        AlertContent(condition: condition, plan: plan, history: history, now: now)
    }

    @Test func backupFailedCarriesTheReason() throws {
        let plan = plan()
        var history = PlanRunHistory()
        history.record(record(.backup, .failed(exitCode: 1, reason: "Fatal: unable to open repository"), planID: plan.id))
        history.record(record(.backup, .skipped(.onBattery), planID: plan.id))
        let alert = try #require(content(.backupFailed, plan: plan, history: history))
        #expect(alert.title == "Backup failed — Home")
        #expect(alert.body == "Fatal: unable to open repository")
    }

    @Test func backupFailedWithoutARecordStillSaysSomething() throws {
        let alert = try #require(content(.backupFailed, plan: plan()))
        #expect(alert.title == "Backup failed — Home")
        #expect(!alert.body.isEmpty)
    }

    @Test func checkFailed() throws {
        let plan = plan()
        var history = PlanRunHistory()
        history.record(record(.check, .failed(exitCode: 1, reason: "Pack 1a2b is damaged"), planID: plan.id))
        let alert = try #require(content(.checkFailed, plan: plan, history: history))
        #expect(alert.title == "Repository check failed — Home")
        #expect(alert.body == "Pack 1a2b is damaged")
    }

    @Test func configurationError() throws {
        var history = PlanRunHistory()
        history.stoppedReason = "The repository password is wrong"
        let alert = try #require(content(.configurationError, plan: plan(), history: history))
        #expect(alert.title == "Home has stopped — The repository password is wrong")
        #expect(!alert.body.isEmpty)
    }

    /// One banner for the whole agent, however many plans are missing it.
    @Test func fullDiskAccessMissing() throws {
        let alert = try #require(content(.fullDiskAccessMissing, plan: plan()))
        #expect(alert.title == "Full Disk Access is missing — Restorey can't read your files")
        #expect(alert.identifier == "alert.agent.fullDiskAccessMissing")
        #expect(alert.threadIdentifier == "agent")
        #expect(try #require(content(.fullDiskAccessMissing, plan: plan())).identifier == alert.identifier)
        #expect(!alert.body.isEmpty)
    }

    @Test func checkInRejected() throws {
        let alert = try #require(AlertContent(
            condition: .checkInRejected, plan: plan(), history: PlanRunHistory(), now: now, checkInStatus: 404))
        #expect(alert.title == "Check-in URL rejected — Home")
        #expect(alert.body
            == "The monitoring service returned HTTP 404, so it won't alert you if backups stop. Check the URL in this plan's settings.")
        // After a restart the status isn't known.
        let unknown = try #require(content(.checkInRejected, plan: plan()))
        #expect(!unknown.body.contains("HTTP"))
    }

    @Test func loadError() {
        let alert = AlertContent.loadError("config.json can't be read: bad JSON. The file has been left as it is.")
        #expect(alert.title == "Restorey has stopped — its settings can't be read")
        #expect(alert.identifier == "alert.agent.loadError")
        #expect(alert.body == "config.json can't be read: bad JSON. The file has been left as it is.")
    }

    @Test func noRecentSuccessCountsTheDays() throws {
        var history = PlanRunHistory()
        history.lastSuccessAt = now.addingTimeInterval(-3 * 86_400 - 60)
        let plan = plan(created: now.addingTimeInterval(-30 * 86_400))
        #expect(try #require(content(.noRecentSuccess, plan: plan, history: history)).title == "No backup in 3 days — Home")
        history.lastSuccessAt = now.addingTimeInterval(-5.5 * 86_400)
        #expect(try #require(content(.noRecentSuccess, plan: plan, history: history)).title == "No backup in 5 days — Home")
        // Never succeeded: counted from the plan's creation.
        let never = try #require(content(.noRecentSuccess, plan: plan, history: PlanRunHistory()))
        #expect(never.title == "No backup in 30 days — Home")
    }

    @Test func noRecentSuccessSaysOneDay() throws {
        var plan = plan(created: now.addingTimeInterval(-30 * 86_400))
        plan.noSuccessAlertDays = 1
        var history = PlanRunHistory()
        history.lastSuccessAt = now.addingTimeInterval(-86_400 - 60)
        #expect(try #require(content(.noRecentSuccess, plan: plan, history: history)).title == "No backup in 1 day — Home")
    }

    @Test func notificationsOffIsNeverPosted() {
        #expect(content(.notificationsOff, plan: plan()) == nil)
    }

    /// One banner per plan and condition: a re-notification replaces the last one. One thread per plan.
    @Test func identifiers() throws {
        let home = plan()
        let other = plan()
        let a = try #require(content(.backupFailed, plan: home))
        let b = try #require(content(.checkFailed, plan: home))
        let c = try #require(content(.backupFailed, plan: other))
        #expect(a.identifier == "alert.\(home.id.uuidString).backupFailed")
        #expect(a.identifier == (try #require(content(.backupFailed, plan: home))).identifier)
        #expect(a.identifier != b.identifier)
        #expect(a.identifier != c.identifier)
        #expect(a.threadIdentifier == "plan.\(home.id.uuidString)")
        #expect(a.threadIdentifier == b.threadIdentifier)
        #expect(a.threadIdentifier != c.threadIdentifier)
    }
}
