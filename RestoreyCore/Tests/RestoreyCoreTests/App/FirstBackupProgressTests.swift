import Foundation
import Testing

@testable import RestoreyCore

/// Times in Brisbane (UTC+10), locale en-AU, as in `MenuPresentationTests`.
@Suite struct FirstBackupProgressTests {
    private static let locale = Locale(identifier: "en_AU")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return calendar
    }()
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 14, minute: 20))!

    private static let plan: Plan = {
        var plan = Plan.newHotPlan(
            name: "Local · new", repository: .raw(repository: "/Users/me/restorey-test/new", environmentNames: []),
            origin: .created, hostLabel: "pepper", sources: ["/Users/me"], exclusions: [], now: now)
        plan.recoveryKitConfirmedAt = now
        plan.setupCompletedAt = now
        return plan
    }()

    private static func record(_ operation: ResticOperation, _ outcome: RunOutcome, endedMinute: Int) -> RunRecord {
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 14, minute: endedMinute))!
        return RunRecord(
            id: UUID(), planID: plan.id, operation: operation, trigger: .manual, startedAt: end.addingTimeInterval(-30),
            endedAt: end, outcome: outcome, summary: nil, logFile: "")
    }

    private static func status(_ phase: PlanPhase, last: RunRecord? = nil, backup: RunRecord? = nil) -> PlanStatus {
        PlanStatus(plan: plan, phase: phase, lastRecord: last, nextRunAt: nil, alerts: [], lastBackup: backup)
    }

    private static func make(
        _ status: PlanStatus?, baseline: FirstBackupProgress.Baseline = .init(nil), rate: Double? = nil
    ) -> FirstBackupProgress {
        FirstBackupProgress.make(
            plan: status, baseline: baseline, bytesPerSecond: rate, now: now, calendar: calendar, locale: locale)
    }

    @Test func beforeAnyStatusItIsStarting() {
        #expect(Self.make(nil) == FirstBackupProgress(title: "Starting the first backup…"))
    }

    @Test func queuedBehindAnotherJobItIsWaiting() {
        // Running with no progress: the backup waits its turn, e.g. behind the size measurement an adopt queued.
        let progress = Self.make(Self.status(.running(nil, retrying: nil)))
        #expect(progress.title == "Waiting to start")
        #expect(progress.detail == "The first backup starts as soon as the repository is free.")
        #expect(progress.fraction == nil)
        #expect(!progress.finished)
    }

    @Test func runningShowsThePercentageAndTheMenusDetail() {
        let backup = BackupStatus(
            percentDone: 0.384, totalBytes: 505_000_000_000, bytesDone: 191_000_000_000, secondsRemaining: 21_600)
        let progress = Self.make(Self.status(.running(backup, retrying: nil)), rate: 24_000_000)
        #expect(progress.title == "Backing up — 38%")
        #expect(progress.detail == "191 of 505 GB · ~6 h · 24 MB/s")
        #expect(progress.fraction == 0.384)
    }

    @Test func retryingShowsWhatResticSaid() {
        let progress = Self.make(Self.status(.running(nil, retrying: "Can't reach the repository — retrying")))
        #expect(progress.title == "Backing up")
        #expect(progress.detail == "Retrying: Can't reach the repository — retrying")
    }

    @Test func idleWithNothingNewHasNotStartedYet() {
        let old = Self.record(.catConfig, .success(snapshotID: nil), endedMinute: 1)
        let status = Self.status(.idle, last: old)
        #expect(Self.make(status, baseline: .init(status)).title == "Starting the first backup…")
        // A record from another step (an adopt's size measurement) isn't the backup ending.
        let stats = Self.record(.stats, .success(snapshotID: nil), endedMinute: 2)
        #expect(Self.make(Self.status(.idle, last: stats), baseline: .init(status)).finished == false)
    }

    @Test func aSavedBackupFinishesIt() {
        let before = Self.status(.idle)
        let backup = Self.record(.backup, .success(snapshotID: "abc"), endedMinute: 16)
        let forget = Self.record(.forget(dryRun: false), .success(snapshotID: nil), endedMinute: 17)
        // forget ran after the backup, so the newest record isn't the backup: the saved backup still counts.
        let progress = Self.make(Self.status(.idle, last: forget, backup: backup), baseline: .init(before))
        #expect(progress.finished)
        #expect(progress.title == "Backed up at 14:16")
        #expect(progress.severity == nil)
    }

    @Test func aSkippedOrFailedBackupFinishesItWithTheMenusWording() {
        let before = Self.status(.idle)
        let skipped = Self.record(.backup, .skipped(.onBattery), endedMinute: 16)
        let progress = Self.make(Self.status(.skipped(.onBattery), last: skipped), baseline: .init(before))
        #expect(progress.finished)
        #expect(progress.severity == .warning)
        let failed = Self.record(.backup, .failed(exitCode: 1, reason: "Fatal: unable to open config file"), endedMinute: 16)
        var status = Self.status(.idle, last: failed)
        status.alerts = [.backupFailed]
        let failure = Self.make(status, baseline: .init(before))
        #expect(failure.finished)
        #expect(failure.title == "Backup failed at 14:16")
        #expect(failure.severity == .error)
    }

    @Test func maintenanceAfterTheBackupIsNotWaiting() {
        // The run's forget and check keep the plan running, with no progress, after the snapshot is saved.
        let before = Self.status(.idle)
        let backup = Self.record(.backup, .success(snapshotID: "abc"), endedMinute: 16)
        let progress = Self.make(Self.status(.running(nil, retrying: nil), last: backup, backup: backup), baseline: .init(before))
        #expect(progress.title == "Backed up at 14:16")
        #expect(progress.detail == "Restorey is tidying the repository after it.")
        #expect(progress.finished)
    }
}
