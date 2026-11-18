import Foundation
import Testing
@testable import RestoreyCore

/// Restorey's Shortcuts actions (Task 17e, audit T2): each does what the menu's item does, only when the menu would let
/// it, and says why when it won't. Brisbane time, en-AU.
struct ShortcutRulesTests {
    private static let locale = Locale(identifier: "en_AU")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        calendar.locale = locale
        return calendar
    }()

    private static func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12 - daysAgo, hour: hour, minute: minute))!
    }

    private static let now = at(14, 20)

    private static func plan(_ name: String, setup: Bool = true, kit: Bool = true) -> Plan {
        var plan = Plan.newHotPlan(
            name: name,
            repository: .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "my-backups", prefix: "mac")),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        plan.hasCheckInURL = true
        plan.setupCompletedAt = setup ? now : nil
        plan.recoveryKitConfirmedAt = kit && setup ? now : nil
        return plan
    }

    private static func record(_ plan: Plan, _ outcome: RunOutcome, at end: Date) -> RunRecord {
        RunRecord(
            id: UUID(), planID: plan.id, operation: .backup, trigger: .scheduled,
            startedAt: end.addingTimeInterval(-60), endedAt: end, outcome: outcome, summary: nil, logFile: "")
    }

    private static func line(
        _ plan: Plan, phase: PlanPhase = .idle, last: RunRecord? = nil, saved: RunRecord? = nil,
        setupState: PlanSetupState? = nil
    ) -> PlanStatus {
        PlanStatus(
            plan: plan, phase: phase, lastRecord: last, nextRunAt: at(15, 16), alerts: [], lastBackup: saved,
            repositorySize: nil, setupState: setupState)
    }

    private static func status(_ plans: [PlanStatus], configError: String? = nil) -> AgentStatus {
        AgentStatus(plans: plans, configError: configError, fdaMissing: false, generatedAt: now)
    }

    private static func content(_ status: AgentStatus?, health: AgentHealthState = .healthy) -> MenuContent {
        MenuPresentation.make(
            health: health, status: status, notificationsAuthorised: true, now: now, calendar: calendar, locale: locale)
    }

    private static func backUp(_ planID: UUID?, _ status: AgentStatus?, health: AgentHealthState = .healthy)
        -> Result<ShortcutCall, ShortcutRefusal>
    {
        ShortcutRules.backUp(planID: planID, health: health, content: content(status, health: health), status: status)
    }

    private static func pause(_ planID: UUID?, _ status: AgentStatus?) -> Result<ShortcutCall, ShortcutRefusal> {
        ShortcutRules.pause(planID: planID, health: .healthy, content: content(status), status: status)
    }

    private static func resume(_ planID: UUID?, _ status: AgentStatus?) -> Result<ShortcutCall, ShortcutRefusal> {
        ShortcutRules.resume(planID: planID, health: .healthy, content: content(status), status: status)
    }

    private static func lastBackup(_ planID: UUID?, _ status: AgentStatus?, health: AgentHealthState = .healthy)
        -> Result<LastBackupReport, ShortcutRefusal>
    {
        ShortcutRules.lastBackup(
            planID: planID, health: health, content: content(status, health: health), status: status,
            now: now, calendar: calendar, locale: locale)
    }

    // MARK: The plans offered

    @Test func plansAreTheStatusPlansByIDAndNameInOrder() {
        let home = Self.plan("Home"), photos = Self.plan("Photos")
        let status = Self.status([Self.line(home), Self.line(photos)])
        #expect(ShortcutRules.plans(status) == [
            ShortcutPlan(id: home.id, name: "Home"), ShortcutPlan(id: photos.id, name: "Photos"),
        ])
        #expect(ShortcutRules.plans(nil).isEmpty)
        #expect(ShortcutRules.plans(Self.status([Self.line(home)], configError: "bad JSON")).isEmpty)
    }

    @Test func onlyAConnectingOrUpdatingAgentIsWaitedFor() {
        #expect(!ShortcutRules.isSettled(health: .checking, hasStatus: true))
        #expect(!ShortcutRules.isSettled(health: .updating, hasStatus: true))
        #expect(!ShortcutRules.isSettled(health: .waitingForUpdate, hasStatus: false))
        #expect(!ShortcutRules.isSettled(health: .healthy, hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .healthy, hasStatus: true))
        #expect(ShortcutRules.isSettled(health: .switchedOff, hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .notRunning(reachable: false), hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .damaged, hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .failed("x"), hasStatus: false))
    }

    // MARK: Back Up Now

    @Test func backUpNowWithNoPlanBacksUpEveryPlanAsTheMenuDoes() {
        let home = Self.plan("Home")
        let result = Self.backUp(nil, Self.status([Self.line(home)]))
        #expect(result == .success(ShortcutCall(kind: .backUp(nil), dialog: "Restorey is backing up.")))
    }

    @Test func backUpNowForOnePlan() {
        let home = Self.plan("Home"), photos = Self.plan("Photos")
        let result = Self.backUp(photos.id, Self.status([Self.line(home), Self.line(photos)]))
        #expect(result == .success(ShortcutCall(kind: .backUp(photos.id), dialog: "Backing up “Photos”.")))
    }

    @Test func backUpNowIsRefusedWhereTheMenuDimsIt() {
        let running = Self.plan("Home"), unfinished = Self.plan("New", setup: false), kit = Self.plan("Kit")
        let status = Self.status([
            Self.line(running, phase: .running(nil, retrying: nil)), Self.line(unfinished),
            Self.line(kit, setupState: .needsNewKit),
        ])
        // The menu's own enablement, which the rules follow.
        let choices = Self.content(status).actions.plans
        #expect(choices.map(\.canBackUp) == [false, false, false])
        #expect(Self.backUp(running.id, status) == .failure(ShortcutRefusal("“Home” is already backing up.")))
        #expect(Self.backUp(unfinished.id, status) == .failure(ShortcutRefusal("“New” hasn’t finished setup.")))
        #expect(Self.backUp(kit.id, status) == .failure(ShortcutRefusal("“Kit” needs a new recovery kit saved first.")))
        #expect(Self.backUp(nil, status) == .failure(ShortcutRefusal("No plan can back up now.")))
    }

    @Test func backUpNowForEveryPlanWhileAllAreRunning() {
        let home = Self.plan("Home")
        let status = Self.status([Self.line(home, phase: .running(nil, retrying: nil))])
        #expect(Self.backUp(nil, status) == .failure(ShortcutRefusal("Restorey is already backing up.")))
        #expect(ShortcutRules.alreadyBackingUp(planName: "Home") == "“Home” is already backing up.")
        #expect(ShortcutRules.alreadyBackingUp(planName: nil) == "Restorey is already backing up.")
    }

    @Test func aPlanThatIsGoneIsRefusedByName() {
        let home = Self.plan("Home")
        #expect(Self.backUp(UUID(), Self.status([Self.line(home)]))
            == .failure(ShortcutRefusal("That plan is no longer in Restorey.")))
    }

    @Test func nothingIsAskedOfAnAgentTheMenuCantAct() {
        let home = Self.plan("Home")
        let last = Self.status([Self.line(home)])
        #expect(Self.backUp(nil, last, health: .switchedOff) == .failure(ShortcutRefusal("Backups are switched off.")))
        #expect(Self.backUp(home.id, last, health: .notRunning(reachable: true))
            == .failure(ShortcutRefusal("Backups aren’t running.")))
        #expect(Self.backUp(nil, nil, health: .checking)
            == .failure(ShortcutRefusal("Connecting to Restorey’s background process.")))
        #expect(Self.backUp(nil, last, health: .waitingForUpdate)
            == .failure(ShortcutRefusal("Updating Restorey’s background process.")))
        #expect(Self.backUp(nil, Self.status([])) == .failure(ShortcutRefusal("Restorey has no backup plans yet.")))
        #expect(Self.backUp(nil, Self.status([Self.line(home)], configError: "bad"))
            == .failure(ShortcutRefusal("Restorey can’t read its settings.")))
    }

    // MARK: Pause and Resume

    @Test func pauseIsTheMenusHourLongPause() {
        let home = Self.plan("Home"), photos = Self.plan("Photos"), paused = Self.plan("Paused")
        let status = Self.status([
            Self.line(home), Self.line(photos, phase: .running(nil, retrying: nil)),
            Self.line(paused, phase: .paused(until: Self.at(15, 0))),
        ])
        #expect(Self.pause(nil, status)
            == .success(ShortcutCall(kind: .pause([home.id, photos.id]), dialog: "Backups are paused for an hour.")))
        #expect(Self.pause(photos.id, status)
            == .success(ShortcutCall(kind: .pause([photos.id]), dialog: "“Photos” is paused for an hour.")))
        #expect(Self.pause(paused.id, status) == .failure(ShortcutRefusal("“Paused” is already paused.")))
    }

    @Test func pauseIsRefusedForAStoppedOrUnfinishedPlan() {
        let stopped = Self.plan("Stopped"), unfinished = Self.plan("New", setup: false)
        let status = Self.status([Self.line(stopped, phase: .stopped(reason: "wrong password")), Self.line(unfinished)])
        #expect(Self.pause(stopped.id, status)
            == .failure(ShortcutRefusal("“Stopped” is stopped, so there’s nothing to pause.")))
        #expect(Self.pause(unfinished.id, status) == .failure(ShortcutRefusal("“New” hasn’t finished setup.")))
        #expect(Self.pause(nil, status) == .failure(ShortcutRefusal("There’s nothing to pause.")))
    }

    @Test func resumeOnlyWhatIsPaused() {
        let home = Self.plan("Home"), paused = Self.plan("Paused")
        let status = Self.status([Self.line(home), Self.line(paused, phase: .paused(until: Self.at(15, 0)))])
        #expect(Self.resume(nil, status)
            == .success(ShortcutCall(kind: .resume([paused.id]), dialog: "Backups have resumed.")))
        #expect(Self.resume(paused.id, status)
            == .success(ShortcutCall(kind: .resume([paused.id]), dialog: "“Paused” has resumed.")))
        #expect(Self.resume(home.id, status) == .failure(ShortcutRefusal("“Home” isn’t paused.")))
        #expect(Self.resume(nil, Self.status([Self.line(home)])) == .failure(ShortcutRefusal("No plan is paused.")))
    }

    // MARK: Get Last Backup

    @Test func lastBackupReportsTheNewestBackupInTheHistoryListsWords() throws {
        let home = Self.plan("Home")
        let saved = Self.record(home, .success(snapshotID: "a"), at: Self.at(14, 16))
        let report = try Self.lastBackup(home.id, Self.status([Self.line(home, last: saved, saved: saved)])).get()
        #expect(report == LastBackupReport(
            planName: "Home", endedAt: Self.at(14, 16), outcome: "Backed up", savedData: true,
            lastSavedAt: Self.at(14, 16), summary: "Home: Backed up — Today at 14:16"))
    }

    @Test func aFailedLastBackupSaysWhyAndKeepsTheLastGoodOne() throws {
        let home = Self.plan("Home")
        let saved = Self.record(home, .success(snapshotID: "a"), at: Self.at(9, 5, daysAgo: 2))
        let failed = Self.record(home, .wrongPassword, at: Self.at(9, 5, daysAgo: 1))
        let report = try Self.lastBackup(home.id, Self.status([Self.line(home, last: failed, saved: saved)])).get()
        #expect(report.outcome == "Backup failed")
        #expect(!report.savedData)
        #expect(report.endedAt == Self.at(9, 5, daysAgo: 1))
        #expect(report.lastSavedAt == Self.at(9, 5, daysAgo: 2))
        #expect(report.summary == "Home: Backup failed — Yesterday at 09:05 (wrong password)")
    }

    @Test func withNoPlanTheNewestBackupOfAnyPlan() throws {
        let home = Self.plan("Home"), photos = Self.plan("Photos")
        let older = Self.record(home, .success(snapshotID: "a"), at: Self.at(10, 0))
        let newer = Self.record(photos, .unchanged, at: Self.at(13, 0))
        let status = Self.status([Self.line(home, last: older, saved: older), Self.line(photos, last: newer, saved: newer)])
        #expect(try Self.lastBackup(nil, status).get().summary == "Photos: Backed up — Today at 13:00")
    }

    @Test func noBackupYet() throws {
        let home = Self.plan("Home"), new = Self.plan("New", setup: false)
        let status = Self.status([Self.line(home), Self.line(new)])
        let report = try Self.lastBackup(home.id, status).get()
        #expect(report == LastBackupReport(
            planName: "Home", endedAt: nil, outcome: "No backup yet", savedData: false, lastSavedAt: nil,
            summary: "Home: No backup yet"))
        #expect(try Self.lastBackup(new.id, status).get().summary == "New: Not backing up yet")
    }

    @Test func lastBackupReadsTheLastKnownStatusWhileTheAgentIsDown() throws {
        let home = Self.plan("Home")
        let saved = Self.record(home, .success(snapshotID: "a"), at: Self.at(14, 16))
        let status = Self.status([Self.line(home, last: saved, saved: saved)])
        #expect(try Self.lastBackup(home.id, status, health: .switchedOff).get().outcome == "Backed up")
        #expect(Self.lastBackup(home.id, nil, health: .switchedOff) == .failure(ShortcutRefusal("Backups are switched off.")))
        #expect(Self.lastBackup(UUID(), status) == .failure(ShortcutRefusal("That plan is no longer in Restorey.")))
    }
}

/// Adding to a plan's Folders and Exclusions lists, from the open panel or a Finder drag (Task 17e, audit T3).
struct FolderDropTests {
    private static func folder(_ path: String) -> PickedItem { PickedItem(path: path, kind: .folder) }

    @Test func foldersAreAddedInOrderAndStandardised() {
        let outcome = FolderDrop.addingSources(
            [Self.folder("/Users/me/Documents/"), Self.folder("/Volumes/Photos")], to: ["/Users/me/Pictures"])
        #expect(outcome == FolderDrop.Outcome(
            list: ["/Users/me/Pictures", "/Users/me/Documents", "/Volumes/Photos"], problem: nil))
    }

    @Test func filesAndThingsNotOnThisMacAreRefusedAndSaySo() {
        let outcome = FolderDrop.addingSources(
            [PickedItem(path: "/Users/me/notes.txt", kind: .file), Self.folder("/Users/me/Music")], to: [])
        #expect(outcome.list == ["/Users/me/Music"])
        #expect(outcome.problem == "“notes.txt” isn’t a folder. Only folders and drives can be added.")

        let several = FolderDrop.addingSources([
            PickedItem(path: "/Applications/Mail.app", kind: .file), PickedItem(path: "/Users/me/a.pdf", kind: .file),
            PickedItem(path: "https://example.com", kind: .notOnDisk),
        ], to: [])
        #expect(several.list.isEmpty)
        #expect(several.problem
            == "2 items aren’t folders. Only folders and drives can be added. Only folders and drives on this Mac can be added.")
    }

    @Test func aFolderAlreadyListedIsNotAddedTwice() {
        let outcome = FolderDrop.addingSources(
            [Self.folder("/Users/me/Documents"), Self.folder("/Users/me/Documents/"), Self.folder("/Users/me/Movies")],
            to: ["/Users/me/Documents"])
        #expect(outcome.list == ["/Users/me/Documents", "/Users/me/Movies"])
        #expect(outcome.problem == "2 folders are already in the list.")
        #expect(FolderDrop.addingSources([Self.folder("/Users/me/Documents")], to: ["/Users/me/Documents"]).problem
            == "“Documents” is already in the list.")
    }

    @Test func exclusionsAreGlobEscapedPatternsAndRestoreysOwnFoldersAreDuplicates() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        let identity = try Identity(infoDictionary: [
            "RestoreyRootID": "com.jaydenkerr.restorey", "RestoreyAgentLabel": "com.jaydenkerr.restorey.agent",
            "RestoreyKeychainGroup": "ABCDE12345.com.jaydenkerr.restorey", "RestoreyLogsName": "Restorey",
        ])
        let own = DefaultExclusions.ownFolders(home: home, identity: identity)
        let outcome = FolderDrop.addingExclusions(
            [Self.folder("/Users/me/Downloads [old]"), Self.folder("/Users/me/Library/Application Support/com.jaydenkerr.restorey")],
            to: own)
        #expect(outcome.list == own + [#"/Users/me/Downloads \[old\]"#])
        #expect(outcome.problem == "“com.jaydenkerr.restorey” is already in the list.")
        #expect(FolderDrop.addingExclusions([PickedItem(path: "/Users/me/a.txt", kind: .file)], to: []).problem
            == "“a.txt” isn’t a folder. Only folders and drives can be added.")
    }
}

/// The History rows' Copy Outcome and Copy (Task 17e, audit T4).
struct HistoryCopyTests {
    @Test func copiedTextIsTheRowsWords() {
        let locale = Locale(identifier: "en_AU")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 14, minute: 16))!
        let plan = UUID()
        let failed = RunRecord(
            id: UUID(), planID: plan, operation: .backup, trigger: .scheduled, startedAt: end.addingTimeInterval(-7),
            endedAt: end, outcome: .wrongPassword, summary: nil, logFile: "")
        let row = HistoryPresentation.row(failed, planNames: [plan: "Home"], now: end, calendar: calendar, locale: locale)
        #expect(HistoryPresentation.outcomeText(row) == "Backup failed · wrong password")
        #expect(HistoryPresentation.copyText([row, row])
            == "14:16 · Home · Backup · Backup failed · wrong password · 7 s\n14:16 · Home · Backup · Backup failed · wrong password · 7 s")
    }
}
