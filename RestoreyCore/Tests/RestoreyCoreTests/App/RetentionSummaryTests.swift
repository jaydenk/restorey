import Foundation
import Testing
@testable import RestoreyCore

/// The plain-English line under the Retention tab's counts (Task 16a). Each rule is worded as restic 0.19.1's `forget`
/// documentation words it: `--keep-hourly n` keeps "for the last n hours which have one or more snapshots ... only the
/// most recent one for each hour", on natural boundaries, so a quiet stretch doesn't use up the count.
struct RetentionSummaryTests {
    private static let locale = Locale(identifier: "en_AU")

    private static func text(
        _ hourly: Int, _ daily: Int, _ weekly: Int, _ monthly: Int, cadence: ForgetCadence = .afterEachBackup
    ) -> String {
        RetentionSummary.text(
            retention: Retention(hourly: hourly, daily: daily, weekly: weekly, monthly: monthly), cadence: cadence,
            locale: locale)
    }

    @Test func theDefaultsNameEveryRule() {
        #expect(Self.text(24, 30, 52, 120)
            == "Keeps the newest backup of each hour for the last 24 hours that have one, each day for the last 30 "
            + "days that have one, each week for the last 52 weeks that have one and each month for the last 120 "
            + "months that have one. The rest are removed after each backup.")
    }

    @Test func aRuleSetToZeroIsLeftOut() {
        #expect(Self.text(0, 30, 52, 120)
            == "Keeps the newest backup of each day for the last 30 days that have one, each week for the last 52 "
            + "weeks that have one and each month for the last 120 months that have one. "
            + "The rest are removed after each backup.")
        #expect(Self.text(24, 0, 0, 120)
            == "Keeps the newest backup of each hour for the last 24 hours that have one and each month for the last "
            + "120 months that have one. The rest are removed after each backup.")
    }

    @Test func oneRuleReadsOnItsOwn() {
        #expect(Self.text(0, 0, 0, 12)
            == "Keeps the newest backup of each month for the last 12 months that have one. "
            + "The rest are removed after each backup.")
    }

    @Test func aCountOfOneIsSingular() {
        #expect(Self.text(1, 0, 0, 0)
            == "Keeps the newest backup of the latest hour that has one. The rest are removed after each backup.")
        #expect(Self.text(1, 1, 1, 1)
            == "Keeps the newest backup of the latest hour that has one, the latest day that has one, the latest "
            + "week that has one and the latest month that has one. The rest are removed after each backup.")
        #expect(Self.text(24, 1, 0, 0)
            == "Keeps the newest backup of each hour for the last 24 hours that have one and the latest day that has "
            + "one. The rest are removed after each backup.")
    }

    @Test func largeCountsHaveNoThousandsSeparatorSurprises() {
        #expect(Self.text(0, 0, 0, 9999).contains("the last 9,999 months"))
    }

    @Test func aPolicyThatKeepsNothingToThinKeepsEverything() {
        #expect(Self.text(0, 0, 0, 0) == "Keeps every backup. Nothing is removed.")
    }

    @Test func anAdoptedRepositoryTidiedDailyIsToldSo() {
        #expect(Self.text(0, 7, 0, 0, cadence: .daily)
            == "Keeps the newest backup of each day for the last 7 days that have one. "
            + "The rest are removed once a day.")
    }

    @Test func theFormsTextBecomesASummaryOnlyWhenItReads() {
        var form = ScheduleForm(plan: Plan.newHotPlan(
            name: "x", repository: .raw(repository: "/r", environmentNames: []), origin: .created, hostLabel: "m",
            sources: ["/Users/me"], exclusions: [], now: Date(timeIntervalSince1970: 0)))
        #expect(RetentionSummary.text(form: form, cadence: .afterEachBackup, locale: Self.locale)?.hasPrefix("Keeps the newest backup of each hour") == true)
        form.daily = "ten"
        #expect(RetentionSummary.text(form: form, cadence: .afterEachBackup, locale: Self.locale) == nil)
        form.daily = "0"; form.hourly = "0"; form.weekly = "0"; form.monthly = "0"
        #expect(RetentionSummary.text(form: form, cadence: .afterEachBackup, locale: Self.locale) == nil)
    }

    /// What plain `restic check` reads (0.19.1 `cmd_check.go`, `internal/checker`, `internal/repository/checker.go`):
    /// the snapshots, the index files and the tree blobs (folder lists); it lists the pack files and compares their
    /// sizes, and reads no file contents unless `--read-data` is given.
    @Test func theWeeklyCheckNoteSaysWhatIsDownloadedAndWhatIsNot() {
        #expect(RetentionSummary.weeklyCheckNote
            == "Once a week Restorey checks the backup’s structure. It downloads indexes and folder lists, not "
            + "your files, so it uses little data.")
    }
}
