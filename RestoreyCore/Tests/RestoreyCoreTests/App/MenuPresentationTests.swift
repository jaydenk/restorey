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
        rates: [UUID: Double] = [:], now: Date = now
    ) -> MenuContent {
        MenuPresentation.make(
            health: health, status: status, notificationsAuthorised: notifications, rates: rates,
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
        #expect(content.actions == MenuActions(
            backUpNow: true, pause: true, resume: false, perPlanSubmenus: false,
            plans: [PlanChoice(id: plan.id, name: "MacBook", canBackUp: true, canPause: true, canResume: false, canRestore: true)]))
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
        #expect(content.plans[0].detail == "Skipped: Photos isn't connected")
        #expect(content.plans[0].severity == .warning)
        #expect(content.icon == .warning)
    }

    @Test func aPlanThatHasNotBackedUpYet() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, backedUpAt: nil, next: Self.at(14, 25))]))
        #expect(content.plans[0].status == "No backup yet")
        #expect(content.plans[0].detail == "Next 14:25")
    }

    // MARK: Running

    @Test func twoPlansOneRunning() {
        let idle = Self.plan("MacBook")
        let photos = Self.plan("Photos drive")
        let progress = BackupStatus(
            percentDone: 0.42, totalFiles: 100, filesDone: 42, totalBytes: 2_900_000_000, bytesDone: 1_200_000_000,
            secondsRemaining: 360)
        let content = Self.make(
            Self.status([Self.line(idle), Self.line(photos, phase: .running(progress, retrying: nil))]),
            rates: [photos.id: 18_000_000])
        #expect(content.icon == .backingUp)
        #expect(content.plans[1].status == "Backing up")
        #expect(content.plans[1].progress == 0.42)
        #expect(content.plans[1].detail == "1.2 of 2.9 GB · ~6 min · 18 MB/s")
        #expect(content.plans[0].status == "Backed up at 14:16")
        #expect(content.plans[0].progress == nil)
        #expect(content.actions.perPlanSubmenus)
        #expect(content.actions.backUpNow)
        // Per plan for the submenus: the running one can't be backed up again, but can be paused.
        #expect(content.actions.plans == [
            PlanChoice(id: idle.id, name: "MacBook", canBackUp: true, canPause: true, canResume: false, canRestore: true),
            PlanChoice(id: photos.id, name: "Photos drive", canBackUp: false, canPause: true, canResume: false, canRestore: true),
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

    @Test func runningWithoutProgressOrRateYet() {
        let plan = Self.plan()
        let content = Self.make(Self.status([Self.line(plan, phase: .running(nil, retrying: nil))]))
        #expect(content.plans[0].status == "Backing up")
        #expect(content.plans[0].progress == nil)
        #expect(content.plans[0].detail == nil)
        #expect(content.icon == .backingUp)
    }

    @Test func retryingReplacesTheProgressDetail() {
        let plan = Self.plan()
        let progress = BackupStatus(percentDone: 0.1, totalBytes: 1_000_000_000, bytesDone: 100_000_000)
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
        #expect(content.banners[0].title == "Notifications are off — Restorey can't alert you")
        #expect(content.banners[0].severity == .warning)
        #expect(content.banners[0].action == .turnOnNotifications)
        #expect(content.banners[0].dismiss == nil)
    }

    @Test func notificationsOffAlertGivesTheSameSingleBanner() {
        let plan = Self.plan()
        let content = Self.make(
            Self.status([Self.line(plan, alerts: [.notificationsOff])]), notifications: false)
        #expect(content.banners.map(\.title) == ["Notifications are off — Restorey can't alert you"])
        let fromAlert = Self.make(Self.status([Self.line(plan, alerts: [.notificationsOff])]), notifications: nil)
        #expect(fromAlert.banners.map(\.title) == ["Notifications are off — Restorey can't alert you"])
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
        #expect(content.plans[0].detail == "3 files couldn't be read")
        #expect(content.plans[0].severity == .warning)
        #expect(content.icon == .warning)
        let one = Self.make(Self.status([Self.line(plan, outcome: .warning(unreadable: 1))]))
        #expect(one.plans[0].detail == "1 file couldn't be read")
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
            #expect(content.banners[0].title == "The background agent isn't running")
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
        #expect(content.banners.map(\.title) == ["The background agent is switched off"])
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

    @Test func severalPlansNameTheOneABannerIsAbout() {
        let first = Self.plan("MacBook", checkIn: false)
        let second = Self.plan("Photos drive")
        let content = Self.make(Self.status([Self.line(first), Self.line(second)]))
        #expect(content.banners[0].detail == "MacBook: add a check-in URL so you hear if this Mac stops.")
    }

    // MARK: Updating and an unanswering agent

    @Test func updatingWhileABackupFinishes() {
        let plan = Self.plan()
        let progress = BackupStatus(percentDone: 0.9, totalBytes: 1_000_000_000, bytesDone: 900_000_000, secondsRemaining: 120)
        let running = Self.status([Self.line(plan, phase: .running(progress, retrying: nil))])
        let content = Self.make(running, health: .updating)
        #expect(content.icon == .backingUp)
        #expect(content.plans.count == 1)
        #expect(content.plans[0].name == "MacBook")
        #expect(content.plans[0].status == "Finishing the current backup before updating the agent")
        #expect(content.plans[0].detail == "~2 min left")
        #expect(content.actions == MenuActions(backUpNow: false, pause: false, resume: false, perPlanSubmenus: false))
    }

    @Test func updatingWithNothingRunningSaysSo() {
        let content = Self.make(Self.status([Self.line(Self.plan())]), health: .updating)
        #expect(content.plans.isEmpty)
        #expect(content.message == "Updating the background agent…")
        #expect(content.icon == .ok)
        let waiting = Self.make(Self.status([Self.line(Self.plan())]), health: .waitingForUpdate)
        #expect(waiting.message == "Updating the background agent…")
    }

    @Test func anAgentThatStopsAnsweringKeepsItsLastStateAsAWarningForThirtyMinutes() {
        let plan = Self.plan()
        let running = Self.status(
            [Self.line(plan, phase: .running(nil, retrying: nil))], generatedAt: Self.at(14, 0))
        let content = Self.make(running, health: .notRunning(reachable: false))
        #expect(content.icon == .warning)
        #expect(content.plans.map(\.status) == ["Backing up (agent not answering)"])
        #expect(content.banners.allSatisfy { $0.severity == .warning })
        #expect(content.banners.first?.action == .restartAgent)
        #expect(content.actions == MenuActions(backUpNow: false, pause: false, resume: false, perPlanSubmenus: false))

        let edge = Self.make(running, health: .notRunning(reachable: false), now: Self.at(14, 30))
        #expect(edge.icon == .warning)
        let late = Self.make(running, health: .notRunning(reachable: false), now: Self.at(14, 31))
        #expect(late.icon == .error)
        #expect(late.banners.map(\.title) == ["The background agent isn't running"])
        #expect(late.plans.isEmpty)
    }

    @Test func nothingRunningMeansNoGraceEvenForAFreshStatus() {
        let idle = Self.status([Self.line(Self.plan())], generatedAt: Self.at(14, 19))
        let paused = Self.status(
            [Self.line(Self.plan(), phase: .paused(until: Self.at(15, 0)), next: nil)], generatedAt: Self.at(14, 19))
        for status in [idle, paused] {
            let content = Self.make(status, health: .notRunning(reachable: false))
            #expect(content.icon == .error)
            #expect(content.banners.map(\.title) == ["The background agent isn't running"])
            #expect(content.plans.isEmpty)
        }
    }

    @Test func aStatusFromTheFutureGetsNoGrace() {
        let running = Self.status(
            [Self.line(Self.plan(), phase: .running(nil, retrying: nil))], generatedAt: Self.at(14, 25))
        let content = Self.make(running, health: .notRunning(reachable: false))
        #expect(content.icon == .error)
        #expect(content.banners.map(\.title) == ["The background agent isn't running"])
    }

    @Test func noRecentSuccessKeepsTheSkipReasonAsDetail() {
        let plan = Self.plan()
        let skipped = Self.line(
            plan, phase: .skipped(.volumeNotMounted("Photos")), backedUpAt: Self.at(14, 16, daysAgo: 4),
            alerts: [.noRecentSuccess])
        let content = Self.make(Self.status([skipped]))
        #expect(content.plans[0].status == "No successful backup in 3 days")
        #expect(content.plans[0].detail == "Skipped: Photos isn't connected")
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
        #expect(checking.icon == .ok)
        #expect(checking.message == "Connecting to the background agent…")
        #expect(checking.plans.isEmpty)
        let healthyWithoutStatus = Self.make(nil)
        #expect(healthyWithoutStatus.plans.isEmpty)
        #expect(healthyWithoutStatus.icon == .ok)
        // Healthy again, with the fresh status still on its way.
        #expect(healthyWithoutStatus.message == "Connecting to the background agent…")
    }

    /// Fix round 1, F3: with no plan, the menu is the way back into a setup window that was closed, with the
    /// unfinished-setup banner's words.
    @Test func noPlansYet() {
        let content = Self.make(Self.status([]))
        #expect(content.icon == .warning)
        #expect(content.message == "No backup plans yet")
        #expect(content.actions.plans.isEmpty)
        #expect(content.banners == [MenuBanner(
            severity: .warning, title: "Setup not finished", detail: "Set up a backup plan to start backing up this Mac.",
            action: .setUp)])
        #expect(BannerAction.setUp.buttonTitle == "Finish Setup…")
    }

    @Test func aDamagedInstallationAndARegistrationFailure() {
        let damaged = Self.make(nil, health: .damaged)
        #expect(damaged.icon == .error)
        #expect(damaged.message == "Restorey's installation is damaged — reinstall it from the download")
        let failed = Self.make(nil, health: .failed("Couldn't register the agent."))
        #expect(failed.icon == .error)
        #expect(failed.message == "Couldn't register the agent.")
    }

    @Test func aConfigurationErrorStopsEverything() {
        var status = Self.status([Self.line(Self.plan())])
        status.configError = "config.json is from a newer version"
        let content = Self.make(status)
        #expect(content.icon == .error)
        #expect(content.message == "Restorey can't read its settings: config.json is from a newer version")
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

    // MARK: Helpers

    private static func text(of content: MenuContent) -> String {
        var parts: [String] = content.banners.flatMap { [$0.title, $0.detail] }
        parts += content.plans.flatMap { [$0.name, $0.status, $0.detail ?? "", $0.destination] }
        parts.append(content.message ?? "")
        return parts.joined(separator: "\n")
    }
}
