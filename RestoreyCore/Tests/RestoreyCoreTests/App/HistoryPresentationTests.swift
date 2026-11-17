import Foundation
import Testing
@testable import RestoreyCore

/// The History list (UI design §6.4, mockup `v0.1-settings.html`): one row per run, in the menu's wording, never
/// "Failed" for a paused, skipped or system-stopped run. Brisbane time, en-AU.
struct HistoryPresentationTests {
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
    private static let macBook = UUID()
    private static let photos = UUID()
    private static let names = [macBook: "MacBook → B2", photos: "Photos drive → B2"]

    private static func record(
        _ outcome: RunOutcome, _ operation: ResticOperation = .backup, plan: UUID = macBook, at end: Date = at(14, 16),
        seconds: TimeInterval = 7, summary: BackupSummary? = nil, logFile: String = "runs/x/20261112T041600Z-backup.log"
    ) -> RunRecord {
        RunRecord(
            id: UUID(), planID: plan, operation: operation, trigger: .scheduled, startedAt: end.addingTimeInterval(-seconds),
            endedAt: end, outcome: outcome, summary: summary, logFile: logFile)
    }

    private static func row(_ record: RunRecord) -> HistoryRow {
        HistoryPresentation.row(record, planNames: names, now: now, calendar: calendar, locale: locale)
    }

    // MARK: Task 16b: the files that couldn't be read

    @Test func aWarningRowWithItemsCarriesThemForTheSheet() {
        let items = [UnreadableItem(path: "/Users/me/a", reason: "operation not permitted")]
        var warning = Self.record(.warning(unreadable: 3))
        warning.unreadableItems = items
        let row = Self.row(warning)
        #expect(row.unreadable == UnreadableSummary(count: 3, items: items))
        // The words are unchanged.
        #expect(row.detail == "3 files couldn't be read · 7 s")
        // An older record has none, and so has any other outcome.
        #expect(Self.row(Self.record(.warning(unreadable: 3))).unreadable == nil)
        var success = Self.record(.success(snapshotID: "a"))
        success.unreadableItems = items
        #expect(Self.row(success).unreadable == nil)
    }

    // MARK: Task 16d: the biggest additions

    private static let additions = BiggestAdditions(
        files: [
            .init(path: "/Users/me/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", bytesAdded: 1_100_000_000),
            .init(path: "/Users/me/Pictures/Lightroom/Lightroom Catalog.lrcat", bytesAdded: 312_000_000),
            .init(path: "/Users/me/Library/Logs/big.log", bytesAdded: 45_600_000),
            .init(path: "/Users/me/notes.txt", bytesAdded: 900),
        ],
        folders: [.init(path: "/Users/me/Pictures/Photos Library.photoslibrary", bytesAdded: 1_100_000_000)],
        totalBytesAdded: 1_457_600_900)

    @Test func aBackupRowNamesItsThreeBiggestFilesWithTheListsBehindShow() {
        var record = Self.record(.success(snapshotID: "a"), summary: BackupSummary(dataAdded: 2_100_000, totalDuration: 7, snapshotID: "a"))
        record.biggestAdditions = Self.additions
        let row = Self.row(record)
        #expect(row.biggestAdditions == BiggestAdditionsSummary(
            line: "Biggest additions: Photos.sqlite 1.1 GB, Lightroom Catalog.lrcat 312 MB, big.log 46 MB",
            additions: Self.additions))
        // The detail line is unchanged.
        #expect(row.detail == "2.1 MB · 7 s")
        // A warning's row has them too.
        var warning = Self.record(.warning(unreadable: 1))
        warning.biggestAdditions = Self.additions
        #expect(Self.row(warning).biggestAdditions?.additions == Self.additions)
    }

    @Test func fewerFilesAreNamedAsTheyAreAndNoneMeansNoLine() {
        var one = Self.record(.success(snapshotID: "a"))
        one.biggestAdditions = BiggestAdditions(files: [.init(path: "/a/b.txt", bytesAdded: 640)], folders: [], totalBytesAdded: 640)
        #expect(Self.row(one).biggestAdditions?.line == "Biggest additions: b.txt 640 B")
        var none = Self.record(.success(snapshotID: "a"))
        none.biggestAdditions = BiggestAdditions(files: [], folders: [], totalBytesAdded: 0)
        #expect(Self.row(none).biggestAdditions == nil)
        // A record from before Task 16d, and any other step, have none.
        #expect(Self.row(Self.record(.success(snapshotID: "a"))).biggestAdditions == nil)
        var check = Self.record(.success(snapshotID: nil), .check)
        check.biggestAdditions = Self.additions
        #expect(Self.row(check).biggestAdditions == nil)
    }

    @Test func theSheetsRowsAreHomeShortenedWithSizesAndFinderWhereThePathExists() {
        let rows = BiggestAdditionsText.rows(
            Self.additions.files, home: URL(fileURLWithPath: "/Users/me"), locale: Self.locale,
            exists: { $0.hasSuffix(".log") })
        #expect(rows.map(\.display) == [
            "~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", "~/Pictures/Lightroom/Lightroom Catalog.lrcat",
            "~/Library/Logs/big.log", "~/notes.txt",
        ])
        #expect(rows.map(\.size) == ["1.1 GB", "312 MB", "46 MB", "900 B"])
        #expect(rows.map(\.canOpenInFinder) == [false, false, true, false])
        #expect(BiggestAdditionsText.caption(Self.additions, locale: Self.locale)
            == "Files added 1.5 GB to the repository, after compression. These added the most.")
    }

    // MARK: The mockup's rows

    @Test func aBackupShowsWhatItAddedAndHowLongItTook() {
        let row = Self.row(Self.record(
            .success(snapshotID: "abc"), summary: BackupSummary(dataAdded: 2_100_000, totalDuration: 7.2, snapshotID: "abc")))
        #expect(row.time == "14:16")
        #expect(row.plan == "MacBook → B2")
        #expect(row.operation == "Backup")
        #expect(row.outcome == "Backed up")
        #expect(row.detail == "2.1 MB · 7 s")
        #expect(row.kind == .success)
        #expect(row.logFile == "runs/x/20261112T041600Z-backup.log")
    }

    /// Ruling R65: a run restic skipped as unchanged reads as backed up.
    @Test func anUnchangedBackupIsBackedUp() {
        let row = Self.row(Self.record(.unchanged, summary: BackupSummary(dataAdded: 0, totalDuration: 5)))
        #expect(row.outcome == "Backed up")
        #expect(row.detail == "0 B · 5 s")
        #expect(row.kind == .success)
    }

    @Test func aWarningSaysHowManyFilesCouldntBeRead() {
        let row = Self.row(Self.record(.warning(unreadable: 3), summary: BackupSummary(dataAdded: 640, totalDuration: 5)))
        #expect(row.outcome == "Backed up")
        #expect(row.detail == "3 files couldn't be read · 640 B · 5 s")
        #expect(row.kind == .warning)
        #expect(Self.row(Self.record(.warning(unreadable: 1))).detail == "1 file couldn't be read · 7 s")
    }

    @Test func maintenanceStepsSayWhatTheyDid() {
        #expect(Self.row(Self.record(.success(snapshotID: nil), .forget(dryRun: false))).outcome == "Old snapshots tidied")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .prune)).outcome == "Unused data removed")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .check)).outcome == "Repository checked")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .unlock)).outcome == "Stale locks removed")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .stats)).outcome == "Size measured")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .initRepository)).outcome == "Repository created")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .forget(dryRun: false))).operation == "Tidy")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .check)).operation == "Check")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .unlock)).operation == "Unlock")
    }

    @Test func aSkipIsItsReasonWithNoLogAndNoDuration() {
        let row = Self.row(Self.record(.skipped(.volumeNotMounted("Photos")), plan: Self.photos, seconds: 0, logFile: ""))
        #expect(row.outcome == "Skipped: Photos isn't connected")
        #expect(row.plan == "Photos drive → B2")
        #expect(row.detail == nil)
        #expect(row.logFile == nil)
        #expect(row.kind == .skipped)
    }

    // MARK: Never "Failed" for a paused, cancelled or system-stopped run

    @Test func stopsThatArentFailuresSaySo() {
        let paused = Self.row(Self.record(.paused, seconds: 65))
        #expect(paused.outcome == "Paused")
        #expect(paused.kind == .skipped)
        #expect(paused.detail == "1 min")
        #expect(Self.row(Self.record(.cancelled)).outcome == "Cancelled")
        #expect(Self.row(Self.record(.cancelled)).kind == .skipped)
        let system = Self.row(Self.record(.stoppedBySystem))
        #expect(system.outcome == "Stopped: the Mac was restarting, shutting down or logging out")
        #expect(system.kind == .skipped)
        for outcome in [RunOutcome.paused, .cancelled, .stoppedBySystem, .skipped(.onBattery)] {
            #expect(!Self.row(Self.record(outcome)).outcome.contains("ailed"))
        }
    }

    @Test func aLockHeldElsewhereIsAWarningNotAFailure() {
        let row = Self.row(Self.record(.locked, .check))
        #expect(row.outcome == "Repository busy: another restic held its lock")
        #expect(row.kind == .warning)
    }

    /// Task 14b: a confirmed removal of earlier snapshots reads as what it did, counted from the IDs restic removed.
    @Test func aRemovalOfEarlierSnapshotsSaysHowManyWent() {
        let ids = (0..<12).map { String(repeating: String($0 % 10), count: 64) }
        let row = Self.row(Self.record(.success(snapshotID: nil), .forgetSnapshots(ids: ids)))
        #expect(row.operation == "Tidy")
        #expect(row.outcome == "Removed 12 earlier snapshots")
        #expect(row.kind == .success)
        #expect(Self.row(Self.record(.success(snapshotID: nil), .forgetSnapshots(ids: [ids[0]]))).outcome
            == "Removed 1 earlier snapshot")
        #expect(Self.row(Self.record(.success(snapshotID: nil), .forgetSnapshots(ids: []), logFile: "")).outcome
            == "No earlier snapshots needed removing")
        let failed = Self.row(Self.record(.failed(exitCode: 1, reason: "the backend is unreachable"), .forgetSnapshots(ids: ids)))
        #expect(failed.outcome == "Couldn't remove earlier snapshots")
        #expect(failed.detail == "the backend is unreachable · 7 s")
        #expect(failed.kind == .failure)
        let locked = Self.row(Self.record(.locked, .forgetSnapshots(ids: ids)))
        #expect(locked.outcome == "Repository busy: another restic held its lock")
        #expect(locked.kind == .warning)
    }

    // MARK: Failures, with the menu's reasons

    @Test func failuresNameTheStepAndTheMenusReason() {
        let wrong = Self.row(Self.record(.wrongPassword))
        #expect(wrong.outcome == "Backup failed")
        #expect(wrong.detail == "wrong password · 7 s")
        #expect(wrong.kind == .failure)
        #expect(Self.row(Self.record(.repositoryMissing)).detail == "repository not found · 7 s")
        #expect(Self.row(Self.record(.credentialsUnavailable)).detail == "credentials unavailable · 7 s")
        #expect(Self.row(Self.record(.interrupted)).detail == "interrupted · 7 s")
        let check = Self.row(Self.record(.failed(exitCode: 1, reason: "pack abc is damaged"), .check))
        #expect(check.outcome == "Check failed")
        #expect(check.detail == "pack abc is damaged · 7 s")
        #expect(Self.row(Self.record(.failed(exitCode: 3, reason: "x"), .forget(dryRun: false))).outcome == "Tidy failed")
    }

    /// Live finding 1 (build 812): a probe's `cat config` finding nothing is the answer setup expects for a new
    /// address ("Nothing here yet."), not a failure, so it never shows under Problems. A backup that finds no
    /// repository still fails.
    @Test func aProbeFindingNoRepositoryIsAnAnswerNotAFailure() {
        let probe = Self.record(.repositoryMissing, .catConfig, at: Self.at(14, 16))
        let row = Self.row(probe)
        #expect(row.operation == "Probe")
        #expect(row.outcome == "No repository there yet")
        #expect(row.detail == "7 s")
        #expect(row.kind == .success)
        let rows = HistoryPresentation.rows(
            [probe, Self.record(.repositoryMissing, at: Self.at(13, 0))], plan: nil, filter: .problems,
            planNames: Self.names, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(rows.map(\.outcome) == ["Backup failed"])
        // Any other probe failure is still one.
        let refused = Self.row(Self.record(.wrongPassword, .catConfig))
        #expect(refused.outcome == "Probe failed")
        #expect(refused.kind == .failure)
    }

    // MARK: Time and plan

    @Test func earlierDaysShowTheirDate() {
        #expect(Self.row(Self.record(.unchanged, at: Self.at(9, 5, daysAgo: 1))).time == "Yesterday, 09:05")
        #expect(Self.row(Self.record(.unchanged, at: Self.at(9, 5, daysAgo: 3))).time == "9 Nov, 09:05")
    }

    @Test func aPlanTheStatusDoesntListIsNamedAsSuch() {
        #expect(Self.row(Self.record(.unchanged, plan: UUID())).plan == "Deleted plan")
    }

    // MARK: Filters

    @Test func filtersPickPlansAndOutcomes() {
        let records = [
            Self.record(.success(snapshotID: "a"), at: Self.at(14, 16)),
            Self.record(.success(snapshotID: nil), .forget(dryRun: false), at: Self.at(14, 16)),
            Self.record(.skipped(.volumeNotMounted("Photos")), plan: Self.photos, at: Self.at(13, 15)),
            Self.record(.wrongPassword, plan: Self.photos, at: Self.at(12, 0)),
            Self.record(.warning(unreadable: 2), at: Self.at(11, 0)),
            Self.record(.paused, at: Self.at(10, 0)),
        ]
        func outcomes(_ plan: UUID?, _ filter: HistoryFilter) -> [String] {
            HistoryPresentation.rows(
                records, plan: plan, filter: filter, planNames: Self.names, now: Self.now, calendar: Self.calendar,
                locale: Self.locale
            ).map(\.outcome)
        }
        #expect(outcomes(nil, .everything).count == 6)
        #expect(outcomes(Self.photos, .everything) == ["Skipped: Photos isn't connected", "Backup failed"])
        #expect(outcomes(nil, .backups) == ["Backed up", "Backed up"])
        #expect(outcomes(nil, .problems) == ["Backup failed", "Backed up"])
        #expect(outcomes(nil, .notRun) == ["Skipped: Photos isn't connected", "Paused"])
        #expect(HistoryFilter.allCases.map(\.title) == ["Everything", "Backups", "Problems", "Skipped and paused"])
    }

    @Test func rowsAreNewestFirstWhateverOrderTheyArrive() {
        let older = Self.record(.unchanged, at: Self.at(9, 0))
        let newer = Self.record(.unchanged, at: Self.at(10, 0))
        let rows = HistoryPresentation.rows(
            [older, newer], plan: nil, filter: .everything, planNames: Self.names, now: Self.now, calendar: Self.calendar,
            locale: Self.locale)
        #expect(rows.map(\.id) == [newer.id, older.id])
    }

    // MARK: The log file

    @Test func aLogIsOpenedOnlyInsideTheLogsFolder() {
        let logs = URL(fileURLWithPath: "/Users/me/Library/Logs/Restorey", isDirectory: true)
        #expect(HistoryPresentation.logURL("runs/a/b.log", logsDirectory: logs)?.path
            == "/Users/me/Library/Logs/Restorey/runs/a/b.log")
        #expect(HistoryPresentation.logURL("", logsDirectory: logs) == nil)
        #expect(HistoryPresentation.logURL("../../.ssh/id_ed25519", logsDirectory: logs) == nil)
        #expect(HistoryPresentation.logURL("runs/../../x.log", logsDirectory: logs) == nil)
        #expect(HistoryPresentation.logURL("/etc/passwd", logsDirectory: logs) == nil)
        #expect(HistoryPresentation.logURL("agent.log", logsDirectory: logs) == nil)
    }
}
