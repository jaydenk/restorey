import Foundation
import Testing
@testable import RestoreyCore

/// One test per state of the approved mockup (`docs/mockups/v0.1-menu-states.html`), pinning the exact strings.
/// Times are in Brisbane (UTC+10, no daylight saving) and the locale is en-AU.
struct MenuPresentationTests {
    private static let locale = Locale(identifier: "en_AU")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        calendar.locale = locale
        return calendar
    }()

    /// Thursday 12 November 2026, 14:20 in Brisbane.
    private static let now = at(14, 20)

    private static func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12 - daysAgo, hour: hour, minute: minute))!
        return day
    }

    // MARK: Fixtures

    private static func plan(
        _ name: String = "MacBook", checkIn: Bool = true, offMacDismissed: Bool = false,
        repository: Repository? = nil, setup: Bool = true, kit: Bool = true
    ) -> Plan {
        var plan = Plan.newHotPlan(
            name: name,
            repository: repository ?? .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "my-backups", prefix: "mac")),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        plan.hasCheckInURL = checkIn
        plan.offMacNoteDismissed = offMacDismissed
        plan.noSuccessAlertDays = 3
        plan.setupCompletedAt = setup ? now : nil
        plan.recoveryKitConfirmedAt = kit && setup ? now : nil
        return plan
    }

    private static func record(_ plan: Plan, _ outcome: RunOutcome, at end: Date, operation: ResticOperation = .backup) -> RunRecord {
        RunRecord(
            id: UUID(), planID: plan.id, operation: operation, trigger: .scheduled,
            startedAt: end.addingTimeInterval(-60), endedAt: end, outcome: outcome, summary: nil, logFile: "")
    }

    private static func line(
        _ plan: Plan, phase: PlanPhase = .idle, backedUpAt: Date? = at(14, 16), outcome: RunOutcome = .success(snapshotID: "a"),
        last: RunRecord? = nil, next: Date? = at(15, 16), alerts: [AlertCondition] = [],
        size: RepositorySize? = nil, setupState: PlanSetupState? = nil
    ) -> PlanStatus {
        let backup = backedUpAt.map { record(plan, outcome, at: $0) }
        return PlanStatus(
            plan: plan, phase: phase, lastRecord: last ?? backup, nextRunAt: next, alerts: alerts,
            lastBackup: backup, repositorySize: size, setupState: setupState)
    }

    private static func status(_ plans: [PlanStatus], fdaMissing: Bool? = false, generatedAt: Date = now) -> AgentStatus {
        AgentStatus(plans: plans, configError: nil, fdaMissing: fdaMissing, generatedAt: generatedAt)
    }

    private static func make(
        _ status: AgentStatus?, health: AgentHealthState = .healthy, notifications: Bool? = true,
        now: Date = now
    ) -> MenuContent {
        MenuPresentation.make(
            health: health, status: status, notificationsAuthorised: notifications,
            now: now, calendar: calendar, locale: locale)
    }

    // MARK: Idle

    @Test func idleSinglePlan() {
        let plan = Self.plan()
        let size = RepositorySize(bytes: 486_000_000_000, measuredAt: Self.at(14, 20, daysAgo: 3))
        let content = Self.make(Self.status([Self.line(plan, size: size)]))
        #expect(content.icon == .ok)
        #expect(content.banners.isEmpty)
        #expect(content.plans.count == 1)
        let line = content.plans[0]
        #expect(line.id == plan.id)
        #expect(line.name == "MacBook")
        #expect(line.status == "Backed up at 14:16")
        #expect(line.detail == "Next 15:16")
        #expect(line.destination == "B2 · my-backups · 486 GB, 3 days ago")
        #expect(line.progress == nil)
        #expect(line.severity == nil)
        #expect(!line.isPaused)
        // Idle: nothing to pause (owner, 20 Nov 2026).
        #expect(content.actions == MenuActions(
            backUpNow: true, pause: false, resume: false, perPlanSubmenus: false,
            plans: [PlanChoice(id: plan.id, name: "MacBook", canBackUp: true, canPause: false, canResume: false, canRestore: true)]))
    }

    @Test func destinationHasNoSizeBeforeTheFirstMeasurement() {
        let content = Self.make(Self.status([Self.line(Self.plan())]))
        #expect(content.plans[0].destination == "B2 · my-backups")
    }

    @Test func destinationOfOtherRepositories() {
        let plain = Self.plan(repository: .s3(S3Location(
            provider: .s3, endpoint: URL(string: "https://s3.example.com")!, bucket: "b", prefix: "")))
        let local = Self.plan(repository: .raw(repository: "/Volumes/Backup/repo", environmentNames: []))
        let sftp = Self.plan(repository: .raw(repository: "sftp:me@host:/srv/repo", environmentNames: []))
        let content = Self.make(Self.status([Self.line(plain), Self.line(local), Self.line(sftp)]))
        #expect(content.plans.map(\.destination) == ["S3 · b", "Local · repo", "SFTP"])
    }

    @Test func anUnchangedRunStillReadsBackedUpAt() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, outcome: .unchanged)]))
        #expect(content.plans[0].status == "Backed up at 14:16")
        #expect(content.icon == .ok)
    }

    @Test func aBackupFromAnotherDayNamesTheDay() {
        let plan = Self.plan()
        let yesterday = Self.make(Self.status([Self.line(plan, backedUpAt: Self.at(9, 5, daysAgo: 1))]))
        #expect(yesterday.plans[0].status == "Backed up yesterday at 09:05")
        let older = Self.make(Self.status([Self.line(plan, backedUpAt: Self.at(9, 5, daysAgo: 3))]))
        #expect(older.plans[0].status == "Backed up 9 Nov at 09:05")
    }

    @Test func aSkipAfterASuccessKeepsBackedUpAt() {
        let plan = Self.plan()
        let skipped = Self.line(
            plan, phase: .skipped(.volumeNotMounted("Photos")), backedUpAt: Self.at(13, 16), next: nil)
        let content = Self.make(Self.status([skipped]))
        #expect(content.plans[0].status == "Backed up at 13:16")
        #expect(content.plans[0].detail == "Skipped: Photos isn’t connected")
        #expect(content.plans[0].severity == .warning)
        #expect(content.icon == .warning)
    }

    @Test func aPlanThatHasNotBackedUpYet() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, backedUpAt: nil, next: Self.at(14, 25))]))
        #expect(content.plans[0].status == "No backup yet")
        #expect(content.plans[0].detail == "Next 14:25")
    }

    /// Final review m6: a first backup that was cut short says it carries on, and that restic keeps what it uploaded.
    @Test(arguments: [RunOutcome.stoppedBySystem, .interrupted, .paused, .cancelled])
    func aFirstBackupThatWasInterruptedSaysItCarriesOn(outcome: RunOutcome) {
        let plan = Self.plan()
        let interrupted = Self.record(plan, outcome, at: Self.at(10, 5))
        let status = Self.line(plan, backedUpAt: nil, last: interrupted, next: Self.at(10, 25))
        let content = Self.make(Self.status([status]))
        let sentence = "The first backup was interrupted. It carries on at 10:25, keeping what’s already uploaded."
        #expect(content.plans[0].status == "No backup yet")
        #expect(content.plans[0].detail == sentence)
        // The menu's line is short (audit P5); the Overview and the item's tooltip have the sentence.
        #expect(content.plans[0].menuDetail == "Interrupted, carries on at 10:25")
        #expect(content.plans[0].severity == nil)
        #expect(content.icon == .idle, "no backup yet: the plain drive, not the tick")
        // The Overview reads the same facts.
        let overview = MenuPresentation.overview(
            planID: plan.id, health: .healthy, status: Self.status([status]), notificationsAuthorised: true,
            now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(overview?.reason == sentence)
        #expect(overview?.headline == "No backup yet")
    }

    /// Only a first backup, only an interruption, only when the next run is known.
    @Test func theInterruptedFirstBackupSentenceIsLimitedToThoseCases() {
        let plan = Self.plan()
        func detail(_ status: PlanStatus) -> String? { Self.make(Self.status([status])).plans[0].detail }
        let interrupted = Self.record(plan, .interrupted, at: Self.at(10, 5))
        // No next run known: nothing to promise.
        #expect(detail(Self.line(plan, backedUpAt: nil, last: interrupted, next: nil)) == nil)
        // A failed first backup is a failure, not an interruption.
        let failed = Self.record(plan, .failed(exitCode: 1, reason: "no"), at: Self.at(10, 5))
        #expect(detail(Self.line(plan, backedUpAt: nil, last: failed, next: Self.at(10, 25))) == "Next 10:25")
        // A plan that has backed up before.
        #expect(detail(Self.line(plan, last: interrupted, next: Self.at(10, 25))) == "Next 10:25")
        // Nothing has run at all.
        #expect(detail(Self.line(plan, backedUpAt: nil, next: Self.at(10, 25))) == "Next 10:25")
    }

    // MARK: Running

    @Test func twoPlansOneRunning() {
        let idle = Self.plan("MacBook")
        let photos = Self.plan("Photos drive")
        let progress = BackupStatus(
            percentDone: 0.42, totalFiles: 100, filesDone: 42, totalBytes: 2_900_000_000, bytesDone: 1_200_000_000,
            secondsRemaining: 360, scanFinished: true)
        let content = Self.make(
            Self.status([Self.line(idle), Self.line(photos, phase: .running(progress, retrying: nil))]))
        #expect(content.icon == .backingUp)
        #expect(content.plans[1].status == "Backing up")
        #expect(content.plans[1].progress == 0.42)
        #expect(content.plans[1].detail == "1.2 of 2.9 GB · ~6 min")
        #expect(content.plans[0].status == "Backed up at 14:16")
        #expect(content.plans[0].progress == nil)
        #expect(content.actions.perPlanSubmenus)
        #expect(content.actions.backUpNow)
        #expect(content.actions.cancel)
        // Per plan for the submenus: the running one can't be backed up again, but can be paused or cancelled; the idle
        // one has nothing to pause (owner, 20 Nov 2026).
        #expect(content.actions.plans == [
            PlanChoice(id: idle.id, name: "MacBook", canBackUp: true, canPause: false, canResume: false, canRestore: true),
            PlanChoice(
                id: photos.id, name: "Photos drive", canBackUp: false, canPause: true, canResume: false, canRestore: true,
                canCancel: true),
        ])
    }

    /// An unfinished plan can't be backed up, paused, resumed or restored from (fix round 1: it has no recovery
    /// kit and may have no repository). One needing a new kit still has its backups to restore.
    @Test func anUnfinishedPlanCanDoNothing() {
        let plan = Self.plan(setup: false)
        let content = Self.make(Self.status([Self.line(plan, backedUpAt: nil, next: nil)]))
        #expect(content.actions.plans == [
            PlanChoice(id: plan.id, name: "MacBook", canBackUp: false, canPause: false, canResume: false, canRestore: false),
        ])
        let needsKit = Self.plan(kit: false)
        let kitContent = Self.make(Self.status([Self.line(needsKit)]))
        #expect(kitContent.actions.plans.first?.canRestore == true)
        #expect(!content.actions.backUpNow)
    }

    /// Cancel Backup is for a backup that is running now, and only while the agent can be asked.
    @Test func cancelIsOfferedOnlyForARunningBackup() {
        let idle = Self.plan("MacBook")
        let running = Self.plan("Photos drive")
        let quiet = Self.make(Self.status([Self.line(idle)]))
        #expect(!quiet.actions.cancel)
        #expect(quiet.actions.plans.map(\.canCancel) == [false])

        let paused = Self.make(Self.status([Self.line(idle, phase: .paused(until: Self.at(15, 0)))]))
        #expect(!paused.actions.cancel)

        let busy = Self.make(Self.status([Self.line(idle), Self.line(running, phase: .running(nil, retrying: nil))]))
        #expect(busy.actions.cancel)
        #expect(busy.actions.plans.map(\.canCancel) == [false, true])

        // Not while the agent can't be asked: no choices at all, so nothing to cancel.
        let updating = Self.make(
            Self.status([Self.line(running, phase: .running(nil, retrying: nil))]), health: .updating)
        #expect(!updating.actions.cancel)
        #expect(updating.actions.plans.isEmpty)
    }

    @Test func runningWithoutProgressOrRateYet() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, phase: .running(nil, retrying: nil))]))
        #expect(content.plans[0].status == "Backing up")
        #expect(content.plans[0].progress == nil)
        #expect(content.plans[0].detail == nil)
        #expect(content.icon == .backingUp)
    }

    /// Task 16e: restic counts while it backs up, so until it says the count is done there is no fraction, no
    /// percentage and no time left: an indeterminate bar and how many files it has looked at.
    @Test func whileResticIsStillCountingThereIsNoFractionOrTimeLeft() {
        let plan = Self.plan()
        // The archiver has raced past the partial totals: 100% of the files counted so far, in no time at all.
        let counting = BackupStatus(
            percentDone: 1, totalFiles: 412_000, filesDone: 412_000, totalBytes: 300_000_000, bytesDone: 300_000_000,
            secondsRemaining: 0)
        let content = Self.make(Self.status([Self.line(plan, phase: .running(counting, retrying: nil))]))
        let line = content.plans[0]
        #expect(line.status == "Backing up")
        #expect(line.progress == nil)
        #expect(line.isChecking)
        #expect(line.detail == "Checking for changes… 412,000 files so far")
        #expect(content.icon == .backingUp)
        #expect(MenuLayout.rows(content, developer: false).contains(.progress(planID: plan.id, name: line.name, fraction: nil)))
    }

    @Test func theCountOfFilesIsPlainWhenSmallOrNotYetKnown() {
        let plan = Self.plan()
        func detail(_ filesDone: Int) -> String? {
            let status = BackupStatus(percentDone: 0, filesDone: filesDone)
            return Self.make(Self.status([Self.line(plan, phase: .running(status, retrying: nil))])).plans[0].detail
        }
        #expect(detail(0) == "Checking for changes…")
        #expect(detail(1) == "Checking for changes… 1 file so far")
        #expect(detail(999) == "Checking for changes… 999 files so far")
    }

    /// Once restic has said the count is done: the bar, the bytes and the time left, with the fraction clamped.
    @Test func onceResticHasFinishedCountingTheBarAndTimeLeftAppear() {
        let plan = Self.plan()
        let done = BackupStatus(
            percentDone: 1.4, totalFiles: 2_000_000, filesDone: 100, totalBytes: 365_000_000_000, bytesDone: 1_200_000_000,
            secondsRemaining: 360, scanFinished: true)
        let line = Self.make(Self.status([Self.line(plan, phase: .running(done, retrying: nil))])).plans[0]
        #expect(!line.isChecking)
        #expect(line.progress == 1)
        #expect(line.detail == "1.2 of 365 GB · ~6 min")
        #expect(MenuLayout.rows(Self.make(Self.status([Self.line(plan, phase: .running(done, retrying: nil))])), developer: false)
            .contains(.progress(planID: plan.id, name: line.name, fraction: 1)))
    }

    /// A restic that never reports the count (an older agent, or a future restic) keeps "Checking for changes…" up,
    /// with no fraction and no time left even when restic sends a rate, until the run ends; then the settled line.
    @Test func aRunThatNeverReportsTheCountShowsCheckingUntilItEnds() {
        let plan = Self.plan()
        let never = BackupStatus(
            percentDone: 0.5, totalFiles: 10, filesDone: 5, totalBytes: 10, bytesDone: 5, secondsRemaining: 30)
        let running = Self.make(Self.status([Self.line(plan, phase: .running(never, retrying: nil))])).plans[0]
        #expect(running.isChecking)
        #expect(running.progress == nil)
        #expect(running.detail == "Checking for changes… 5 files so far")
        let ended = Self.make(Self.status([Self.line(plan)])).plans[0]
        #expect(!ended.isChecking)
        #expect(ended.progress == nil)
        #expect(ended.status == "Backed up at 14:16")
        #expect(ended.detail != running.detail)
    }

    @Test func retryingReplacesTheProgressDetail() {
        let plan = Self.plan()
        let progress = BackupStatus(percentDone: 0.1, totalBytes: 1_000_000_000, bytesDone: 100_000_000, scanFinished: true)
        let content = Self.make(Self.status([
            Self.line(plan, phase: .running(progress, retrying: "lock held by another client")),
        ]))
        #expect(content.plans[0].detail == "Retrying: lock held by another client")
        #expect(content.plans[0].progress == 0.1)
    }

    // MARK: Paused

    @Test func paused() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, phase: .paused(until: Self.at(15, 20)), next: nil)]))
        #expect(content.icon == .paused)
        #expect(content.plans[0].status == "Paused")
        #expect(content.plans[0].detail == "Resumes by itself at 15:20")
        #expect(content.plans[0].severity == nil)
        #expect(content.plans[0].isPaused, "drawn grey, never as a failure")
        #expect(content.actions == MenuActions(
            backUpNow: true, pause: false, resume: true, perPlanSubmenus: false,
            plans: [PlanChoice(id: plan.id, name: "MacBook", canBackUp: true, canPause: false, canResume: true, canRestore: true)]))
        #expect(!Self.text(of: content).contains("Failed"))
        #expect(!Self.text(of: content).contains("failed"))
    }

    @Test func resumesTomorrowSaysSo() {
        let plan = Self.plan()
        // 14:20 on Thursday 12 November, Brisbane. A pause until the next calendar day says so; the same day doesn't.
        let tomorrow = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 15, minute: 47))!
        let content = Self.make(Self.status([Self.line(plan, phase: .paused(until: tomorrow), next: nil)]))
        #expect(content.plans[0].detail == "Resumes by itself tomorrow at 15:47")
        let today = Self.make(Self.status([Self.line(plan, phase: .paused(until: Self.at(15, 47)), next: nil)]))
        #expect(today.plans[0].detail == "Resumes by itself at 15:47")
    }

    @Test func aSystemStoppedRunIsNeverFailed() {
        let plan = Self.plan()
        let stopped = Self.record(plan, .stoppedBySystem, at: Self.at(14, 18))
        let content = Self.make(Self.status([Self.line(plan, last: stopped)]))
        #expect(content.icon == .ok)
        #expect(content.plans[0].status == "Backed up at 14:16")
        #expect(!Self.text(of: content).lowercased().contains("failed"))
    }

    // MARK: Warnings

    @Test func notificationsOff() {
        let content = Self.make(Self.status([Self.line(Self.plan())]), notifications: false)
        #expect(content.icon == .warning)
        #expect(content.banners.count == 1)
        #expect(content.banners[0].title == "Notifications are off")
        #expect(content.banners[0].detail
            == "Restorey can’t alert you. Turn them on so a problem with a backup reaches you.")
        #expect(content.banners[0].planID == nil)
        #expect(content.banners[0].severity == .warning)
        #expect(content.banners[0].action == .turnOnNotifications)
        #expect(content.banners[0].dismiss == nil)
    }

    @Test func notificationsOffAlertGivesTheSameSingleBanner() {
        let plan = Self.plan()
        let content = Self.make(
            Self.status([Self.line(plan, alerts: [.notificationsOff])]), notifications: false)
        #expect(content.banners.map(\.title) == ["Notifications are off"])
        let fromAlert = Self.make(Self.status([Self.line(plan, alerts: [.notificationsOff])]), notifications: nil)
        #expect(fromAlert.banners.map(\.title) == ["Notifications are off"])
    }

    @Test func noOffMacMonitoringCanBeAddedOrDismissed() {
        let plan = Self.plan(checkIn: false)
        let content = Self.make(Self.status([Self.line(plan)]))
        #expect(content.icon == .warning)
        #expect(content.banners.count == 1)
        #expect(content.banners[0].title == "No off-Mac monitoring")
        #expect(content.banners[0].detail == "Add a check-in URL so you hear if this Mac stops.")
        #expect(content.banners[0].severity == .warning)
        #expect(content.banners[0].action == .addCheckInURL(plan.id))
        #expect(content.banners[0].dismiss == .dismissOffMacNote(plan.id))
    }

    @Test func aDismissedOffMacNoteLeavesNoBannerAndNoWarning() {
        let plan = Self.plan(checkIn: false, offMacDismissed: true)
        let content = Self.make(Self.status([Self.line(plan)]))
        #expect(content.banners.isEmpty)
        #expect(content.icon == .ok)
    }

    @Test func unreadableFiles() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, outcome: .warning(unreadable: 3))]))
        #expect(content.plans[0].status == "Backed up at 14:16")
        #expect(content.plans[0].detail == "3 files couldn’t be read")
        #expect(content.plans[0].severity == .warning)
        #expect(content.icon == .warning)
        let one = Self.make(Self.status([Self.line(plan, outcome: .warning(unreadable: 1))]))
        #expect(one.plans[0].detail == "1 file couldn’t be read")
    }

    @Test func checkInRejected() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, alerts: [.checkInRejected])]))
        #expect(content.plans[0].detail == "The check-in service rejected the last ping")
        #expect(content.plans[0].severity == .warning)
        #expect(content.icon == .warning)
    }

    // MARK: Errors

    @Test func fullDiskAccessMissing() {
        let content = Self.make(Self.status([Self.line(Self.plan())], fdaMissing: true))
        #expect(content.icon == .error)
        #expect(content.banners.count == 1)
        #expect(content.banners[0].title == "Full Disk Access is missing")
        #expect(content.banners[0].detail == "Backups would be empty.")
        #expect(content.banners[0].severity == .error)
        #expect(content.banners[0].action == .openFullDiskAccess)
    }

    @Test func aClearedFullDiskAccessIsNotShownFromAStaleAlert() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, alerts: [.fullDiskAccessMissing])], fdaMissing: false))
        #expect(content.banners.isEmpty)
        let unknown = Self.make(Self.status([Self.line(plan, alerts: [.fullDiskAccessMissing])], fdaMissing: nil))
        #expect(unknown.banners.map(\.title) == ["Full Disk Access is missing"])
    }

    @Test func aFailedBackupWithAWrongPassword() {
        let plan = Self.plan()
        let failed = Self.record(plan, .wrongPassword, at: Self.at(14, 16))
        let content = Self.make(Self.status([
            Self.line(plan, phase: .stopped(reason: "Wrong password"), backedUpAt: Self.at(13, 16), last: failed, next: nil,
                alerts: [.backupFailed]),
        ]))
        #expect(content.icon == .error)
        #expect(content.plans[0].status == "Backup failed at 14:16")
        #expect(content.plans[0].detail == "wrong password")
        #expect(content.plans[0].severity == .error)
        #expect(content.plans[0].action == .showDetails(plan.id))
    }

    @Test func aFailureShowsItsReason() {
        let plan = Self.plan()
        let failed = Self.record(plan, .failed(exitCode: 1, reason: "restic exited with code 1"), at: Self.at(14, 16))
        let content = Self.make(Self.status([Self.line(plan, last: failed, alerts: [.backupFailed])]))
        #expect(content.plans[0].status == "Backup failed at 14:16")
        #expect(content.plans[0].detail == "restic exited with code 1")
    }

    /// Fix round 2: the line and its reason come from the newest backup record. A maintenance step or a probe that
    /// ran since (and failed) doesn't become "Backup failed at <its time>".
    @Test func aFailedBackupIsTheNewestBackupRecordNotTheNewestRecord() {
        let plan = Self.plan()
        let backup = Self.record(plan, .wrongPassword, at: Self.at(13, 0))
        let probe = Self.record(plan, .failed(exitCode: 1, reason: "a probe’s reason"), at: Self.at(14, 16), operation: .catConfig)
        let status = PlanStatus(
            plan: plan, phase: .idle, lastRecord: probe, nextRunAt: nil, alerts: [.backupFailed], latestBackupRecord: backup)
        let content = Self.make(Self.status([status]))
        #expect(content.plans[0].status == "Backup failed at 13:00")
        #expect(content.plans[0].detail == "wrong password")
    }

    /// Fix round 3, N3: a skip after a failure leaves the alert up (`activeConditions` looks past it), and the line
    /// keeps the failure's time and reason rather than a bare "Backup failed".
    @Test func aSkipAfterAFailureKeepsTheFailuresLine() {
        let plan = Self.plan()
        let failure = Self.record(plan, .wrongPassword, at: Self.at(13, 0))
        let skip = Self.record(plan, .skipped(.onBattery), at: Self.at(14, 0))
        let status = PlanStatus(
            plan: plan, phase: .skipped(.onBattery), lastRecord: skip, nextRunAt: nil, alerts: [.backupFailed],
            latestBackupRecord: skip, latestBackupVerdict: failure)
        let content = Self.make(Self.status([status]))
        #expect(content.plans[0].status == "Backup failed at 13:00")
        #expect(content.plans[0].detail == "wrong password")
    }

    @Test func noRecentSuccess() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, backedUpAt: Self.at(14, 16, daysAgo: 4), alerts: [.noRecentSuccess])]))
        #expect(content.plans[0].status == "No successful backup in 3 days")
        #expect(content.plans[0].severity == .error)
        #expect(content.icon == .error)
    }

    @Test func theAgentIsNotRunning() {
        let plan = Self.plan()
        let old = Self.status([Self.line(plan)], generatedAt: Self.at(12, 0))
        for reachable in [false, true] {
            let content = Self.make(old, health: .notRunning(reachable: reachable))
            #expect(content.icon == .error, "\(reachable)")
            #expect(content.banners.count == 1, "\(reachable)")
            #expect(content.banners[0].title == "Backups aren’t running")
            #expect(content.banners[0].detail == "No backups will happen.")
            #expect(content.banners[0].severity == .error)
            #expect(content.banners[0].action == .restartAgent)
            #expect(content.plans.isEmpty)
            #expect(content.actions == MenuActions(backUpNow: false, pause: false, resume: false, perPlanSubmenus: false))
            #expect(content.message == "Last known: backed up at 14:16")
        }
    }

    @Test func theAgentIsSwitchedOff() {
        let content = Self.make(Self.status([Self.line(Self.plan())]), health: .switchedOff)
        #expect(content.icon == .error)
        #expect(content.banners.map(\.title) == ["Backups are switched off"])
        #expect(content.banners[0].action == .openLoginItems)
        #expect(content.plans.isEmpty)
        #expect(!content.actions.backUpNow)
    }

    @Test func errorsComeBeforeWarnings() {
        let plan = Self.plan(checkIn: false)
        let content = Self.make(Self.status([Self.line(plan)], fdaMissing: true), notifications: false)
        #expect(content.banners.map(\.severity) == [.error, .warning, .warning])
        #expect(content.banners.first?.title == "Full Disk Access is missing")
    }

    // MARK: Setup

    @Test func anUnfinishedPlan() {
        let plan = Self.plan(setup: false)
        let content = Self.make(Self.status([Self.line(plan, backedUpAt: nil, next: nil)]))
        #expect(content.icon == .warning)
        #expect(content.banners.count == 1)
        #expect(content.banners[0].title == "Setup not finished")
        #expect(content.banners[0].severity == .warning)
        #expect(content.banners[0].action == .finishSetup(plan.id))
        #expect(!content.actions.backUpNow)
    }

    @Test func aPlanNeedingANewKit() {
        let plan = Self.plan(kit: false)
        let content = Self.make(Self.status([Self.line(plan, next: nil, setupState: .needsNewKit)]))
        #expect(content.icon == .warning)
        #expect(content.banners.map(\.title) == ["New recovery kit needed"])
        #expect(content.banners[0].action == .saveRecoveryKit(plan.id))
        #expect(content.plans[0].status == "Backed up at 14:16")
    }

    /// Task 17d: a banner about one plan carries the plan, so the menu puts it in that plan's section; its words no
    /// longer need the plan's name in front.
    @Test func aBannerAboutAPlanCarriesThePlan() {
        let first = Self.plan("MacBook", checkIn: false)
        let second = Self.plan("Photos drive")
        let content = Self.make(Self.status([Self.line(first), Self.line(second)]))
        #expect(content.banners == [MenuBanner(
            severity: .warning, title: "No off-Mac monitoring", detail: "Add a check-in URL so you hear if this Mac stops.",
            action: .addCheckInURL(first.id), dismiss: .dismissOffMacNote(first.id), planID: first.id)])
    }

    // MARK: The tick (owner, 20 Nov 2026)

    /// The menu bar shows the tick only when every plan has a backup that saved the data; a plan before its first backup is
    /// the plain drive (`.idle`), so the tick never claims backups that don't exist.
    @Test func theTickNeedsEveryPlanBackedUp() {
        let home = Self.plan("Home"), photos = Self.plan("Photos")
        #expect(Self.make(Self.status([Self.line(home), Self.line(photos)])).icon == .ok)
        #expect(Self.make(Self.status([Self.line(home), Self.line(photos, backedUpAt: nil)])).icon == .idle)
        #expect(Self.make(Self.status([Self.line(home, backedUpAt: nil)])).icon == .idle)
        // No plans at all is already a warning ("No backup plan yet"), never the tick.
        #expect(Self.make(Self.status([])).icon == .warning)
    }

    /// A problem, a backup in progress or a pause still outranks both the tick and the plain drive.
    @Test func problemsRunsAndPausesBeatTheTickAndIdle() {
        let fresh = Self.plan("Fresh"), done = Self.plan("Done")
        let running = Self.status([Self.line(fresh, backedUpAt: nil), Self.line(done, phase: .running(nil, retrying: nil))])
        #expect(Self.make(running).icon == .backingUp)
        let paused = Self.status([Self.line(fresh, backedUpAt: nil), Self.line(done, phase: .paused(until: Self.at(15, 0)))])
        #expect(Self.make(paused).icon == .paused)
        let failed = Self.status([Self.line(done, outcome: .failed(exitCode: 1, reason: "x"), alerts: [.backupFailed])])
        #expect(Self.make(failed).icon > .ok)
    }

    /// While Restorey connects to or updates its background process it knows nothing yet, so no tick.
    @Test func connectingOrUpdatingIsNeverTheTick() {
        #expect(Self.make(nil, health: .checking).icon == .idle)
        #expect(Self.make(nil).icon == .idle)
        #expect(Self.make(Self.status([Self.line(Self.plan())]), health: .updating).icon == .idle)
        #expect(Self.make(Self.status([Self.line(Self.plan())]), health: .waitingForUpdate).icon == .idle)
    }

    // MARK: Updating and an unanswering agent

    @Test func updatingWhileABackupFinishes() {
        let plan = Self.plan()
        let progress = BackupStatus(percentDone: 0.9, totalBytes: 1_000_000_000, bytesDone: 900_000_000, secondsRemaining: 120, scanFinished: true)
        let running = Self.status([Self.line(plan, phase: .running(progress, retrying: nil))])
        let content = Self.make(running, health: .updating)
        #expect(content.icon == .backingUp)
        #expect(content.plans.count == 1)
        #expect(content.plans[0].name == "MacBook")
        #expect(content.plans[0].status == "Finishing the current backup before updating")
        #expect(content.plans[0].detail == "~2 min left")
        #expect(content.actions == MenuActions(backUpNow: false, pause: false, resume: false, perPlanSubmenus: false))
    }

    /// Task 16e: restic's time left means nothing until it has finished counting, in the updating state too.
    @Test func updatingWhileResticIsStillCountingSaysNoTimeLeft() {
        let counting = BackupStatus(percentDone: 1, totalFiles: 9, filesDone: 9, totalBytes: 9, bytesDone: 9, secondsRemaining: 60)
        let running = Self.status([Self.line(Self.plan(), phase: .running(counting, retrying: nil))])
        let content = Self.make(running, health: .updating)
        #expect(content.plans[0].status == "Finishing the current backup before updating")
        #expect(content.plans[0].detail == nil)
        #expect(content.plans[0].progress == nil)
    }

    @Test func updatingWithNothingRunningSaysSo() {
        let content = Self.make(Self.status([Self.line(Self.plan())]), health: .updating)
        #expect(content.plans.isEmpty)
        #expect(content.message == "Updating Restorey’s background process…")
        #expect(content.icon == .idle)
        let waiting = Self.make(Self.status([Self.line(Self.plan())]), health: .waitingForUpdate)
        #expect(waiting.message == "Updating Restorey’s background process…")
    }

    @Test func anAgentThatStopsAnsweringKeepsItsLastStateAsAWarningForThirtyMinutes() {
        let plan = Self.plan()
        let running = Self.status(
            [Self.line(plan, phase: .running(nil, retrying: nil))], generatedAt: Self.at(14, 0))
        let content = Self.make(running, health: .notRunning(reachable: false))
        #expect(content.icon == .warning)
        #expect(content.plans.map(\.status) == ["Backing up (not responding)"])
        #expect(content.banners.allSatisfy { $0.severity == .warning })
        #expect(content.banners.first?.action == .restartAgent)
        #expect(content.actions == MenuActions(backUpNow: false, pause: false, resume: false, perPlanSubmenus: false))

        let edge = Self.make(running, health: .notRunning(reachable: false), now: Self.at(14, 30))
        #expect(edge.icon == .warning)
        let late = Self.make(running, health: .notRunning(reachable: false), now: Self.at(14, 31))
        #expect(late.icon == .error)
        #expect(late.banners.map(\.title) == ["Backups aren’t running"])
        #expect(late.plans.isEmpty)
    }

    @Test func nothingRunningMeansNoGraceEvenForAFreshStatus() {
        let idle = Self.status([Self.line(Self.plan())], generatedAt: Self.at(14, 19))
        let paused = Self.status(
            [Self.line(Self.plan(), phase: .paused(until: Self.at(15, 0)), next: nil)], generatedAt: Self.at(14, 19))
        for status in [idle, paused] {
            let content = Self.make(status, health: .notRunning(reachable: false))
            #expect(content.icon == .error)
            #expect(content.banners.map(\.title) == ["Backups aren’t running"])
            #expect(content.plans.isEmpty)
        }
    }

    @Test func aStatusFromTheFutureGetsNoGrace() {
        let running = Self.status(
            [Self.line(Self.plan(), phase: .running(nil, retrying: nil))], generatedAt: Self.at(14, 25))
        let content = Self.make(running, health: .notRunning(reachable: false))
        #expect(content.icon == .error)
        #expect(content.banners.map(\.title) == ["Backups aren’t running"])
    }

    /// A stopped plan has run nothing since the stop, so that is why no backup has succeeded: the line says the stop.
    @Test func aStoppedPlanThatAlsoHasNoRecentSuccessShowsItsStopReason() {
        let plan = Self.plan()
        let content = Self.make(Self.status([
            Self.line(plan, phase: .stopped(reason: "Wrong password"), backedUpAt: Self.at(14, 16, daysAgo: 4), next: nil,
                alerts: [.noRecentSuccess]),
        ]))
        #expect(content.plans[0].status == "Stopped")
        #expect(content.plans[0].detail == "Wrong password")
        #expect(content.plans[0].severity == .error)
    }

    @Test func noRecentSuccessKeepsTheSkipReasonAsDetail() {
        let plan = Self.plan()
        let skipped = Self.line(
            plan, phase: .skipped(.volumeNotMounted("Photos")), backedUpAt: Self.at(14, 16, daysAgo: 4),
            alerts: [.noRecentSuccess])
        let content = Self.make(Self.status([skipped]))
        #expect(content.plans[0].status == "No successful backup in 3 days")
        #expect(content.plans[0].detail == "Skipped: Photos isn’t connected")
        #expect(content.plans[0].severity == .error)
    }

    @Test func anAgentThatAnswersButIsBrokenIsAnErrorAtOnce() {
        let running = Self.status([Self.line(Self.plan(), phase: .running(nil, retrying: nil))], generatedAt: Self.at(14, 19))
        let content = Self.make(running, health: .notRunning(reachable: true))
        #expect(content.icon == .error)
        #expect(content.plans.isEmpty)
    }

    // MARK: Other states

    @Test func checkingAndUnreadableStatus() {
        let checking = Self.make(nil, health: .checking)
        #expect(checking.icon == .idle)
        #expect(checking.message == "Connecting to Restorey’s background process…")
        #expect(checking.plans.isEmpty)
        let healthyWithoutStatus = Self.make(nil)
        #expect(healthyWithoutStatus.plans.isEmpty)
        #expect(healthyWithoutStatus.icon == .idle)
        // Healthy again, with the fresh status still on its way.
        #expect(healthyWithoutStatus.message == "Connecting to Restorey’s background process…")
    }

    /// Fix round 1, F3: with no plan, the menu is the way back into a setup window that was closed, with the
    /// unfinished-setup banner's words.
    @Test func noPlansYet() {
        let content = Self.make(Self.status([]))
        #expect(content.icon == .warning)
        // The banner says it; a second line saying the same went (Task 17d).
        #expect(content.message == nil)
        #expect(content.actions.plans.isEmpty)
        #expect(content.banners == [MenuBanner(
            severity: .warning, title: "No backup plan yet", detail: "Set up a backup plan to start backing up this Mac.",
            action: .setUp)])
        #expect(BannerAction.setUp.buttonTitle == "Finish Setup…")
    }

    @Test func aDamagedInstallationAndARegistrationFailure() {
        let damaged = Self.make(nil, health: .damaged)
        #expect(damaged.icon == .error)
        #expect(damaged.message == "Restorey’s installation is damaged")
        #expect(damaged.messageDetail == "Reinstall Restorey from the download.")
        let failed = Self.make(nil, health: .failed("Couldn’t register the agent."))
        #expect(failed.icon == .error)
        // The sentence ends in a system error of any length, so it is the line's tooltip (audit P5).
        #expect(failed.message == "Backups couldn’t be set up")
        #expect(failed.messageDetail == "Couldn’t register the agent.")
    }

    @Test func aConfigurationErrorStopsEverything() {
        var status = Self.status([Self.line(Self.plan())])
        status.configError = "config.json is from a newer version"
        let content = Self.make(status)
        #expect(content.icon == .error)
        // Never the raw error in a menu line (audit P5): the banner opens Settings → Plans, which shows it.
        #expect(content.message == nil)
        #expect(content.plans.isEmpty)
        #expect(content.banners == [MenuBanner(
            severity: .error, title: "Restorey can’t read its settings", detail: "config.json is from a newer version",
            action: .showSettingsError)])
    }

    /// Carried from the old `statusIconState` tests: a plan the agent stopped (a configuration problem) is an
    /// error even before any failure alert is raised.
    @Test func aStoppedPlanIsAnError() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, phase: .stopped(reason: "Wrong password"), next: nil)]))
        #expect(content.icon == .error)
        #expect(content.plans[0].status == "Stopped")
        #expect(content.plans[0].detail == "Wrong password")
        #expect(content.plans[0].severity == .error)
    }

    @Test func worstStateWins() {
        let running = Self.plan("A")
        let paused = Self.plan("B")
        let progress = BackupStatus(percentDone: 0.5, totalBytes: 10, bytesDone: 5)
        let both = Self.make(Self.status([
            Self.line(running, phase: .running(progress, retrying: nil)),
            Self.line(paused, phase: .paused(until: Self.at(15, 0)), next: nil),
        ]))
        #expect(both.icon == .paused)
        #expect(StatusIconState.ok < .backingUp && StatusIconState.backingUp < .paused)
        #expect(StatusIconState.paused < .warning && StatusIconState.warning < .error)
    }

    // MARK: Task 17d: short menu lines, the destination, the tooltip

    /// Audit P5: only Restorey's own short reasons are a menu line; restic's error and an agent's stop reason stay in
    /// `detail` (the Overview, the item's tooltip).
    @Test func theMenuDetailIsNeverARawError() {
        let plan = Self.plan()
        let raw = Self.record(plan, .failed(exitCode: 1, reason: "Fatal: unable to open config file: Stat: 403"), at: Self.at(14, 16))
        let failed = Self.make(Self.status([Self.line(plan, last: raw, alerts: [.backupFailed])])).plans[0]
        #expect(failed.detail == "Fatal: unable to open config file: Stat: 403")
        #expect(failed.menuDetail == nil)
        let password = Self.record(plan, .wrongPassword, at: Self.at(14, 16))
        let wrong = Self.make(Self.status([Self.line(plan, last: password, alerts: [.backupFailed])])).plans[0]
        #expect(wrong.detail == "wrong password")
        #expect(wrong.menuDetail == "Wrong password")
        let stopped = Self.make(Self.status([Self.line(plan, phase: .stopped(reason: "The repository was not found"), next: nil)]))
        #expect(stopped.plans[0].menuDetail == nil)
        let progress = BackupStatus(percentDone: 0.1, totalBytes: 1_000_000_000, bytesDone: 100_000_000, scanFinished: true)
        let retrying = Self.make(Self.status([
            Self.line(plan, phase: .running(progress, retrying: "lock held by another client")),
        ]))
        #expect(retrying.plans[0].menuDetail == "Retrying after a problem")
    }

    /// Audit P5: one thing per menu line; the rest is counted, and in the tooltip.
    @Test func severalIssuesShowTheFirstAndCountTheRest() {
        let plan = Self.plan()
        let content = Self.make(Self.status([
            Self.line(plan, phase: .skipped(.onBattery), outcome: .warning(unreadable: 3), alerts: [.checkInRejected]),
        ]))
        #expect(content.plans[0].detail
            == "Skipped while on battery · 3 files couldn’t be read · The check-in service rejected the last ping")
        #expect(content.plans[0].menuDetail == "Skipped while on battery (+2 more)")
    }

    @Test func aSettledPlansMenuDetailIsItsNextRun() {
        let content = Self.make(Self.status([Self.line(Self.plan())]))
        #expect(content.plans[0].menuDetail == "Next 15:16")
        #expect(content.plans[0].hasBackup)
        #expect(!content.plans[0].isRunning)
    }

    /// Audit P3: a plan named after its repository (setup's default) doesn't repeat it under its name.
    @Test func theDestinationDoesNotRepeatThePlansName() {
        let named = Self.plan("B2 · my-backups")
        #expect(Self.make(Self.status([Self.line(named)])).plans[0].destination == nil)
        let size = RepositorySize(bytes: 486_000_000_000, measuredAt: Self.at(14, 20, daysAgo: 3))
        #expect(Self.make(Self.status([Self.line(named, size: size)])).plans[0].destination == "486 GB, 3 days ago")
        #expect(Self.make(Self.status([Self.line(Self.plan("MacBook"), size: size)])).plans[0].destination
            == "B2 · my-backups · 486 GB, 3 days ago")
    }

    /// Review minor 3: setup names a networked raw repository "restic · sftp" while the line says "SFTP"; either name
    /// already says where it backs up. Names are compared as a person reads them, case and spacing aside.
    @Test func theDestinationComparesNamesAsTheyRead() {
        let sftp = Repository.raw(repository: "sftp:me@host:/srv/repo", environmentNames: [])
        for name in ["restic · sftp", "SFTP", " sftp "] {
            #expect(Self.make(Self.status([Self.line(Self.plan(name, repository: sftp))])).plans[0].destination == nil, "\(name)")
        }
        #expect(Self.make(Self.status([Self.line(Self.plan("Server", repository: sftp))])).plans[0].destination == "SFTP")
        let local = Repository.raw(repository: "/Volumes/Backup/repo", environmentNames: [])
        #expect(Self.make(Self.status([Self.line(Self.plan("Local · repo", repository: local))])).plans[0].destination == nil)
        #expect(Self.make(Self.status([Self.line(Self.plan("b2 · MY-BACKUPS"))])).plans[0].destination == nil)
    }

    /// Audit T9: the status item's tooltip.
    @Test func theStatusItemsTooltip() {
        let plan = Self.plan()
        #expect(Self.make(Self.status([Self.line(plan)])).toolTip == "Restorey — Last backup at 14:16")
        #expect(Self.make(Self.status([Self.line(plan, backedUpAt: Self.at(9, 5, daysAgo: 1))])).toolTip
            == "Restorey — Last backup yesterday at 09:05")
        #expect(Self.make(Self.status([Self.line(plan, backedUpAt: nil)])).toolTip == "Restorey — No backup yet")
        let progress = BackupStatus(percentDone: 0.5, totalBytes: 10, bytesDone: 5)
        #expect(Self.make(Self.status([Self.line(plan, phase: .running(progress, retrying: nil))])).toolTip
            == "Restorey — Backing up")
        #expect(Self.make(Self.status([Self.line(plan, phase: .paused(until: Self.at(15, 0)))])).toolTip
            == "Restorey — Paused")
        // The worst problem: an error before a warning, a banner's words, or a plan's (named when there are several).
        #expect(Self.make(Self.status([Self.line(plan)]), notifications: false).toolTip
            == "Restorey — Notifications are off")
        #expect(Self.make(Self.status([Self.line(plan)], fdaMissing: true), notifications: false).toolTip
            == "Restorey — Full Disk Access is missing")
        let failed = Self.record(plan, .wrongPassword, at: Self.at(14, 16))
        let other = Self.plan("Photos")
        #expect(Self.make(Self.status([Self.line(other), Self.line(plan, last: failed, alerts: [.backupFailed])])).toolTip
            == "Restorey — MacBook: Backup failed at 14:16")
        #expect(Self.make(nil, health: .checking).toolTip == "Restorey — Connecting to Restorey’s background process…")
        #expect(Self.make(nil, health: .notRunning(reachable: true)).toolTip == "Restorey — Backups aren’t running")
        // A sentence that starts with the app's name isn't given it twice (review minor 2).
        #expect(Self.make(nil, health: .damaged).toolTip == "Restorey’s installation is damaged")
        var unreadable = Self.status([Self.line(plan)])
        unreadable.configError = "config.json is from a newer version"
        #expect(Self.make(unreadable).toolTip == "Restorey can’t read its settings")
    }

    /// Review minor 2: with several plans, a problem about one plan names it in the tooltip, as a plan's line does.
    @Test func theTooltipNamesThePlanAProblemIsAbout() {
        let photos = Self.plan("Photos drive", checkIn: false)
        #expect(Self.make(Self.status([Self.line(Self.plan()), Self.line(photos)])).toolTip
            == "Restorey — Photos drive: No off-Mac monitoring")
        #expect(Self.make(Self.status([Self.line(photos)])).toolTip == "Restorey — No off-Mac monitoring")
    }

    // MARK: Helpers

    private static func text(of content: MenuContent) -> String {
        var parts: [String] = content.banners.flatMap { [$0.title, $0.detail] }
        parts += content.plans.flatMap { [$0.name, $0.status, $0.detail ?? "", $0.menuDetail ?? "", $0.destination ?? ""] }
        parts.append(content.message ?? "")
        return parts.joined(separator: "\n")
    }
}
