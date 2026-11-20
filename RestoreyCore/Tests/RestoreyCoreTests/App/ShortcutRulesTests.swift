import Dispatch
import Foundation
import Synchronization
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

    private static func pause(
        _ planID: UUID?, _ status: AgentStatus?, length: PauseLength = .oneHour
    ) -> Result<ShortcutCall, ShortcutRefusal> {
        ShortcutRules.pause(planID: planID, length: length, health: .healthy, content: content(status), status: status)
    }

    private static func cancel(_ planID: UUID?, _ status: AgentStatus?) -> Result<ShortcutCall, ShortcutRefusal> {
        ShortcutRules.cancel(planID: planID, health: .healthy, content: content(status), status: status)
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
        #expect(ShortcutRules.isSettled(health: .waitingForRunningBackup(longWait: false), hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .waitingForRunningBackup(longWait: true), hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .damaged, hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .failed("x"), hasStatus: false))
        #expect(ShortcutRules.isSettled(health: .signatureUntrusted, hasStatus: false))
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

    @Test func pauseSaysHowLongForEachLength() {
        let home = Self.plan("Home"), photos = Self.plan("Photos")
        let status = Self.status([
            Self.line(home, phase: .running(nil, retrying: nil)), Self.line(photos, phase: .running(nil, retrying: nil)),
        ])
        let all: [PauseLength: String] = [
            .oneHour: "Backups are paused for an hour.", .fourHours: "Backups are paused for 4 hours.",
            .oneDay: "Backups are paused until tomorrow.",
        ]
        let one: [PauseLength: String] = [
            .oneHour: "“Home” is paused for an hour.", .fourHours: "“Home” is paused for 4 hours.",
            .oneDay: "“Home” is paused until tomorrow.",
        ]
        for length in PauseLength.allCases {
            #expect(Self.pause(nil, status, length: length)
                == .success(ShortcutCall(kind: .pause([home.id, photos.id]), dialog: all[length]!)))
            #expect(Self.pause(home.id, status, length: length)
                == .success(ShortcutCall(kind: .pause([home.id]), dialog: one[length]!)))
        }
    }

    @Test func pauseKeepsItsRefusalsForEveryLength() {
        let paused = Self.plan("Paused")
        let status = Self.status([Self.line(paused, phase: .paused(until: Self.at(15, 0)))])
        for length in PauseLength.allCases {
            #expect(Self.pause(paused.id, status, length: length)
                == .failure(ShortcutRefusal("“Paused” is already paused.")))
            #expect(Self.pause(nil, status, length: length) == .failure(ShortcutRefusal("Nothing is backing up, so there’s nothing to pause.")))
        }
    }

    // MARK: Cancel

    @Test func cancelStopsWhatIsRunning() {
        let home = Self.plan("Home"), photos = Self.plan("Photos"), docs = Self.plan("Docs")
        let status = Self.status([
            Self.line(home, phase: .running(nil, retrying: nil)), Self.line(photos, phase: .running(nil, retrying: nil)),
            Self.line(docs),
        ])
        #expect(Self.cancel(nil, status)
            == .success(ShortcutCall(kind: .cancel([home.id, photos.id]), dialog: "Cancelled every backup in progress.")))
        #expect(Self.cancel(home.id, status)
            == .success(ShortcutCall(kind: .cancel([home.id]), dialog: "Cancelled the backup of “Home”.")))
    }

    @Test func cancelIsRefusedWhenNothingIsBackingUp() {
        let home = Self.plan("Home")
        let status = Self.status([Self.line(home)])
        #expect(Self.cancel(nil, status) == .failure(ShortcutRefusal("There’s no backup to cancel.")))
        #expect(Self.cancel(home.id, status) == .failure(ShortcutRefusal("“Home” isn’t backing up.")))
        #expect(Self.cancel(UUID(), status) == .failure(ShortcutRefusal("That plan is no longer in Restorey.")))
        let paused = Self.status([Self.line(home, phase: .paused(until: Self.at(15, 0)))])
        #expect(Self.cancel(home.id, paused) == .failure(ShortcutRefusal("“Home” isn’t backing up.")))
    }

    /// The agent's reply says a pause was already stopping the run, so nothing was cancelled: the dialog says that
    /// instead of claiming a cancel.
    @Test func cancelSaysWhenAPauseWasAlreadyStoppingTheRun() {
        let call = ShortcutCall(kind: .cancel([UUID()]), dialog: "Cancelled the backup of “Home”.")
        #expect(ShortcutRules.cancelDialog(call, results: [("Home", .alreadyPausing)])
            == "“Home” is already pausing, so there was nothing to cancel.")
        #expect(ShortcutRules.cancelDialog(call, results: [("Home", .stoppedARun)]) == call.dialog)
        // An agent that doesn't say (unknown), or a run that had just ended, keeps today's wording.
        #expect(ShortcutRules.cancelDialog(call, results: [("Home", .unknown)]) == call.dialog)
        #expect(ShortcutRules.cancelDialog(call, results: [("Home", .nothingToCancel)]) == call.dialog)
    }

    @Test func cancelAcrossPlansNamesTheOnesAPauseWon() {
        let all = ShortcutCall(kind: .cancel([UUID(), UUID()]), dialog: "Cancelled every backup in progress.")
        #expect(ShortcutRules.cancelDialog(all, results: [("Home", .alreadyPausing), ("Photos", .alreadyPausing)])
            == "“Home” and “Photos” are already pausing, so there was nothing to cancel.")
        #expect(ShortcutRules.cancelDialog(all, results: [("Home", .stoppedARun), ("Photos", .alreadyPausing)])
            == "Cancelled the backup of “Home”. “Photos” is already pausing, so there was nothing to cancel.")
        #expect(ShortcutRules.cancelDialog(all, results: [("Home", .stoppedARun), ("Photos", .unknown)]) == all.dialog)
    }

    @Test func cancelSaysWhyWhenRestoreyCantBeAsked() {
        let none = ShortcutRules.cancel(
            planID: nil, health: .notRunning(reachable: true), content: Self.content(nil, health: .notRunning(reachable: true)),
            status: nil)
        #expect(none == .failure(ShortcutRefusal("Backups aren’t running.")))
    }

    @Test func pauseIsTheMenusHourLongPause() {
        let home = Self.plan("Home"), photos = Self.plan("Photos"), paused = Self.plan("Paused")
        let status = Self.status([
            Self.line(home), Self.line(photos, phase: .running(nil, retrying: nil)),
            Self.line(paused, phase: .paused(until: Self.at(15, 0))),
        ])
        // Only a backup in progress is paused (owner, 20 Nov 2026): the idle "Home" is left alone, and refused by name.
        #expect(Self.pause(nil, status)
            == .success(ShortcutCall(kind: .pause([photos.id]), dialog: "Backups are paused for an hour.")))
        #expect(Self.pause(home.id, status)
            == .failure(ShortcutRefusal("“Home” isn’t backing up, so there’s nothing to pause.")))
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
        #expect(Self.pause(nil, status) == .failure(ShortcutRefusal("Nothing is backing up, so there’s nothing to pause.")))
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

    // MARK: Reading what an item is (review 17e, Important 1)

    /// A folder, a file, a package, a link to each of the first two, and a broken link, in a fresh temporary folder.
    private static func fixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderDropTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("Folder link"), withDestinationURL: root.appendingPathComponent("Folder"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("notes link"), withDestinationURL: root.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("Broken link"), withDestinationURL: root.appendingPathComponent("Gone"))
        return root
    }

    /// A resolver of its own (its own gate, a deadline no test reaches), so these never meet the app's shared one.
    private static let resolver = LinkResolver(deadline: 3600)

    @Test func aLinkToAFolderIsAFolderAndKeepsThePathChosen() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Folder", "Folder link", "notes.txt", "notes link", "Tool.app", "Broken link", "Never there"]
        let items = await FolderDrop.look(at: names.map { root.appendingPathComponent($0) }, resolver: Self.resolver).items
        #expect(items.map(\.kind) == [.folder, .folder, .file, .file, .file, .missing, .missing])
        // The path the person chose, not where the link leads (the add rule compares sources by where they lead).
        #expect(items[1].path == root.appendingPathComponent("Folder link").path)
        let web = await FolderDrop.look(at: [URL(string: "https://example.com")!], resolver: Self.resolver)
        #expect(web.items.map(\.kind) == [.notOnDisk])
    }

    @Test func aLinkedFolderIsAddedAndIsTheSamePlaceAsItsTarget() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = await FolderDrop.look(at: [root.appendingPathComponent("Folder link")], resolver: Self.resolver)
        let added = FolderDrop.addingSources(link.items, to: [], repository: nil, leads: link.leads)
        #expect(added.problem == nil)
        #expect(added.list == [root.appendingPathComponent("Folder link").path])
        let folder = await FolderDrop.look(
            at: [root.appendingPathComponent("Folder")], against: added.list, resolver: Self.resolver)
        let again = FolderDrop.addingSources(folder.items, to: added.list, repository: nil, leads: folder.leads)
        #expect(again.problem == "“Folder” is already in the list.")
    }

    /// A folder reached through a link into a listed folder is already backed up; the link's own path is outside it.
    @Test func aFolderReachedThroughALinkIntoAListedFolderIsCovered() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderDropTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: downloads)
        let look = await FolderDrop.look(at: [link], against: [home.path], resolver: Self.resolver)
        let outcome = FolderDrop.addingSources(look.items, to: [home.path], repository: nil, home: "/Users/me", leads: look.leads)
        #expect(outcome.list == [home.path])
        #expect(outcome.problem == "“link” is already included in “home”.")
        // Judged by the paths alone, the link is outside the listed folder.
        #expect(FolderDrop.addingSources(look.items, to: [home.path], repository: nil, home: "/Users/me").problem == nil)
    }

    /// L157: reading what was dropped follows links, which a volume that stops answering can hold up for good. The
    /// read runs on a thread of its own against the deadline, one outstanding at a time (`LinkResolver`): past the
    /// deadline each item is judged by its path as written (a folder only when written as one, links not followed),
    /// and a second add while the first is still stuck gives up at once rather than leave another blocked thread. Each
    /// such add says so under the list. The follower is held until released, so a look that waited for it would never
    /// return (handshake as in `LinkResolverTests`).
    @Test func aLookPastItsDeadlineJudgesItemsByPathAndAStuckOneGivesUpAtOnce() async {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let calls = FollowCount()
        let resolver = LinkResolver(deadline: 0.05) { path in
            if calls.add() == 1 {
                entered.signal()
                release.wait()
                finished.signal()
            }
            return path
        }
        let urls = [
            URL(fileURLWithPath: "/Volumes/Gone/Photos/", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/Gone/notes.txt", isDirectory: false), URL(string: "https://example.com")!,
        ]
        let byPath = FolderDrop.Look(
            items: [
                PickedItem(path: "/Volumes/Gone/Photos", kind: .folder), PickedItem(path: "/Volumes/Gone/notes.txt", kind: .file),
                PickedItem(path: "https://example.com", kind: .notOnDisk),
            ],
            leads: [:], checkedInTime: false)
        let pastDeadline = await FolderDrop.look(at: urls, against: ["/Volumes/Gone"], resolver: resolver)
        #expect(pastDeadline == byPath)
        guard resolver.gate.isBusy else {
            Issue.record("the deadline passed before the look was admitted, so no work was held")
            return
        }
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { entered.wait() }
        let whileStuck = await FolderDrop.look(at: urls, resolver: resolver)
        #expect(whileStuck == byPath)
        #expect(calls.value == 1, "no second thread was started behind the stuck one")

        // The folder as written is added, the file isn't taken for one, and the list says the check didn't happen.
        for look in [pastDeadline, whileStuck] {
            let outcome = FolderDrop.addingSources(look, to: ["/Users/me/Music"], repository: nil, home: "/Users/me")
            #expect(outcome.list == ["/Users/me/Music", "/Volumes/Gone/Photos"])
            #expect(outcome.problem == "“notes.txt” isn’t a folder. Only folders and drives can be added. "
                + "Only folders and drives on this Mac can be added.")
            #expect(outcome.note == FolderDrop.uncheckedNote)
            #expect(FolderDrop.addingExclusions(look, to: []).note == FolderDrop.uncheckedNote)
        }
        // Judged by path: inside the listed folder as written.
        let covered = FolderDrop.addingSources(pastDeadline, to: ["/Volumes/Gone"], repository: nil, home: "/Users/me")
        #expect(covered.problem?.hasSuffix("“Photos” is already included in “Gone”.") == true)

        release.signal()
        await OwnThread.run(named: "test wait", qualityOfService: .utility) { finished.wait() }
        for _ in 0..<2000 where resolver.gate.isBusy { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(!resolver.gate.isBusy)
    }

    /// The note is exact, and only for a look that didn't check in time.
    @Test func onlyAnUncheckedLookSaysSo() {
        #expect(FolderDrop.uncheckedNote == "Restorey couldn’t check these in time, so they were added as chosen.")
        let checked = FolderDrop.Look(items: [Self.folder("/Users/me/Music")], leads: [:], checkedInTime: true)
        #expect(FolderDrop.addingSources(checked, to: [], repository: nil, home: "/Users/me").note == nil)
        #expect(FolderDrop.addingExclusions(checked, to: []).note == nil)
    }

    @Test func aMissingItemSaysItCantBeFound() {
        let outcome = FolderDrop.addingSources([PickedItem(path: "/Users/me/Gone", kind: .missing)], to: [], repository: nil)
        #expect(outcome.list.isEmpty)
        #expect(outcome.problem == "“Gone” can’t be found.")
    }

    @Test func foldersAreAddedInOrderAndStandardised() {
        let outcome = FolderDrop.addingSources(
            [Self.folder("/Users/me/Documents/"), Self.folder("/Volumes/Photos")], to: ["/Users/me/Pictures"],
            repository: nil)
        #expect(outcome == FolderDrop.Outcome(
            list: ["/Users/me/Pictures", "/Users/me/Documents", "/Volumes/Photos"], problem: nil))
    }

    @Test func filesAndThingsNotOnThisMacAreRefusedAndSaySo() {
        let outcome = FolderDrop.addingSources(
            [PickedItem(path: "/Users/me/notes.txt", kind: .file), Self.folder("/Users/me/Music")], to: [],
            repository: nil)
        #expect(outcome.list == ["/Users/me/Music"])
        #expect(outcome.problem == "“notes.txt” isn’t a folder. Only folders and drives can be added.")

        let several = FolderDrop.addingSources([
            PickedItem(path: "/Applications/Mail.app", kind: .file), PickedItem(path: "/Users/me/a.pdf", kind: .file),
            PickedItem(path: "https://example.com", kind: .notOnDisk),
        ], to: [], repository: nil)
        #expect(several.list.isEmpty)
        #expect(several.problem
            == "2 items aren’t folders. Only folders and drives can be added. Only folders and drives on this Mac can be added.")
    }

    @Test func aFolderAlreadyListedIsNotAddedTwice() {
        let outcome = FolderDrop.addingSources(
            [Self.folder("/Users/me/Documents"), Self.folder("/Users/me/Documents/"), Self.folder("/Users/me/Movies")],
            to: ["/Users/me/Documents"], repository: nil)
        #expect(outcome.list == ["/Users/me/Documents", "/Users/me/Movies"])
        #expect(outcome.problem == "2 folders are already in the list.")
        #expect(FolderDrop.addingSources([Self.folder("/Users/me/Documents")], to: ["/Users/me/Documents"], repository: nil).problem
            == "“Documents” is already in the list.")
    }

    // MARK: Folders already covered, parents that replace, and the plan's own repository (Task 1)

    private static let home = "/Users/me"
    private static let disk = Repository.raw(repository: "/Volumes/Disk/repo", environmentNames: [])

    private static func adding(
        _ paths: [String], to list: [String] = [], repository: Repository? = nil
    ) -> FolderDrop.Outcome {
        FolderDrop.addingSources(paths.map(folder), to: list, repository: repository, home: home)
    }

    @Test func aFolderInsideAListedSourceIsRefused() {
        let outcome = Self.adding(["/Users/me/Downloads"], to: ["/Users/me"])
        #expect(outcome.list == ["/Users/me"])
        #expect(outcome.problem == "“Downloads” is already included in your home folder.")
    }

    @Test func aFolderInsideAnotherListedFolderNamesIt() {
        let outcome = Self.adding(["/Users/me/Pictures/Trips"], to: ["/Users/me/Pictures"])
        #expect(outcome.list == ["/Users/me/Pictures"])
        #expect(outcome.problem == "“Trips” is already included in “Pictures”.")
    }

    @Test func severalCoveredFoldersAreCounted() {
        let outcome = Self.adding(["/Users/me/Pictures/Trips", "/Users/me/Pictures/Family"], to: ["/Users/me/Pictures"])
        #expect(outcome.list == ["/Users/me/Pictures"])
        #expect(outcome.problem == "2 folders are already included in folders in the list.")
    }

    @Test func aParentReplacesTheFoldersItCovers() {
        let outcome = Self.adding(
            ["/Users/me"], to: ["/Users/me/Downloads", "/Users/me/Documents", "/Volumes/Disk"])
        #expect(outcome.list == ["/Volumes/Disk", "/Users/me"])
        #expect(outcome.problem == nil)
        #expect(outcome.note == "Your home folder includes “Downloads” and “Documents”, so they were taken off the list.")
    }

    @Test func aParentReplacingOneFolderSaysIt() {
        let outcome = Self.adding(["/Users/me/Pictures"], to: ["/Users/me/Pictures/Trips"])
        #expect(outcome.list == ["/Users/me/Pictures"])
        #expect(outcome.note == "“Pictures” includes “Trips”, so it was taken off the list.")
    }

    @Test func aParentReplacingThreeOrMoreCountsThem() {
        let outcome = Self.adding(
            ["/Users/me"], to: ["/Users/me/Downloads", "/Users/me/Documents", "/Users/me/Music"])
        #expect(outcome.list == ["/Users/me"])
        #expect(outcome.note == "Your home folder includes 3 folders that were in the list, so they were taken off it.")
    }

    @Test func aNameThatOnlyStartsTheSameIsNeitherCoveredNorReplaced() {
        #expect(Self.adding(["/Users/me/Documents"], to: ["/Users/me/Doc"]).list == ["/Users/me/Doc", "/Users/me/Documents"])
        let outcome = Self.adding(["/Users/me/Doc"], to: ["/Users/me/Documents"])
        #expect(outcome.list == ["/Users/me/Documents", "/Users/me/Doc"])
        #expect(outcome.problem == nil && outcome.note == nil)
    }

    @Test func theRepositoryFolderIsRefused() {
        let outcome = Self.adding(["/Volumes/Disk/repo"], repository: Self.disk)
        #expect(outcome.list.isEmpty)
        #expect(outcome.problem == "“repo” is where this plan’s backups are kept, so it can’t be backed up.")
    }

    @Test func aFolderInsideTheRepositoryIsRefused() {
        let outcome = Self.adding(["/Volumes/Disk/repo/data"], repository: Self.disk)
        #expect(outcome.list.isEmpty)
        #expect(outcome.problem
            == "“data” is inside the folder where this plan’s backups are kept, so it can’t be backed up.")
    }

    @Test func aFolderHoldingTheRepositoryIsAddedAndSaysTheRepositoryIsLeftOut() {
        let outcome = Self.adding(["/Volumes/Disk"], repository: Self.disk)
        #expect(outcome.list == ["/Volumes/Disk"])
        #expect(outcome.problem == nil)
        #expect(outcome.note == "This plan’s backups are kept inside “Disk”, so that folder is always left out.")
    }

    @Test func noRepositoryYetSkipsTheRepositoryRules() {
        let outcome = Self.adding(["/Volumes/Disk/repo"], repository: nil)
        #expect(outcome.list == ["/Volumes/Disk/repo"])
        #expect(outcome.problem == nil && outcome.note == nil)
    }

    @Test func refusalsJoinWithASpaceInOrderWithTheRepositoryOnesLast() {
        let outcome = Self.adding(
            ["/Volumes/Disk/repo/data", "/Users/me/Gone", "/Users/me/Music"], to: ["/Users/me/Music"],
            repository: Self.disk)
        #expect(outcome.problem == "“Music” is already in the list. "
            + "“data” is inside the folder where this plan’s backups are kept, so it can’t be backed up.")
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

/// How many times a test's link follower was called, from whichever thread calls it.
private final class FollowCount: Sendable {
    private let state = Mutex(0)
    var value: Int { state.withLock { $0 } }
    /// The count after this call.
    func add() -> Int { state.withLock { $0 += 1; return $0 } }
}

/// Pause, Resume or Cancel across several plans where some calls fail (review 17e, Minor 2): the error names each.
struct ShortcutPartialFailureTests {
    @Test func everyFailedPlanIsNamedAndTheOthersSaidDone() {
        let message = ShortcutRules.failureMessage(
            .pause,
            outcomes: [
                .init(planName: "Home", failure: nil),
                .init(planName: "Photos", failure: "Restorey couldn’t reach its background process (timed out)."),
                .init(planName: "Docs", failure: nil),
            ])
        #expect(message == "Restorey couldn’t pause “Photos”: Restorey couldn’t reach its background process (timed out). "
            + "“Home” and “Docs” are paused.")
        let resume = ShortcutRules.failureMessage(
            .resume,
            outcomes: [.init(planName: "Home", failure: "Not now"), .init(planName: "Docs", failure: "Busy.")])
        #expect(resume == "Restorey couldn’t resume “Home”: Not now. Restorey couldn’t resume “Docs”: Busy.")
        let one = ShortcutRules.failureMessage(
            .resume, outcomes: [.init(planName: "Home", failure: nil), .init(planName: "Docs", failure: "Busy.")])
        #expect(one == "Restorey couldn’t resume “Docs”: Busy. “Home” has resumed.")
        #expect(ShortcutRules.failureMessage(.pause, outcomes: [.init(planName: "Home", failure: nil)]) == nil)
    }

    @Test func cancelNamesEachFailedPlanAndThoseCancelled() {
        let message = ShortcutRules.failureMessage(
            .cancel, outcomes: [.init(planName: "Home", failure: nil), .init(planName: "Docs", failure: "Busy.")])
        #expect(message == "Restorey couldn’t cancel “Docs”: Busy. The backup of “Home” was cancelled.")
        let two = ShortcutRules.failureMessage(
            .cancel, outcomes: [.init(planName: "Home", failure: nil), .init(planName: "Photos", failure: nil),
                                .init(planName: "Docs", failure: "Busy.")])
        #expect(two == "Restorey couldn’t cancel “Docs”: Busy. The backups of “Home” and “Photos” were cancelled.")
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
