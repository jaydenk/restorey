import Foundation
import Testing

@testable import RestoreyCore

@Suite struct ScheduleFormTests {
    private static func plan() -> Plan {
        Plan.newHotPlan(
            name: "Test", repository: .raw(repository: "/Volumes/B", environmentNames: []), origin: .created,
            hostLabel: "pepper", sources: ["/Users/me"], exclusions: [], now: Date(timeIntervalSince1970: 0))
    }

    @Test func aNewPlanShowsTheSpecDefaults() {
        let form = ScheduleForm(plan: Self.plan())
        #expect(form.intervalHours == 1)
        #expect(form.battery == .minimumPercent(20))
        #expect([form.hourly, form.daily, form.weekly, form.monthly] == ["24", "30", "52", "120"])
        #expect(ScheduleForm.intervalHours == [1, 2, 4, 6, 12, 24])
    }

    @Test func appliedWritesTheScheduleBatteryAndRetention() throws {
        var form = ScheduleForm(plan: Self.plan())
        form.intervalHours = 6
        form.battery = .neverOnBattery
        form.hourly = " 0 "
        form.monthly = "12"
        let plan = try form.applied(to: Self.plan()).get()
        #expect(plan.schedule == .interval(seconds: 21_600))
        #expect(plan.conditions.battery == .neverOnBattery)
        #expect(plan.retention == Retention(hourly: 0, daily: 30, weekly: 52, monthly: 12))
        #expect(plan.validationErrors().isEmpty)
    }

    @Test func retentionCountsAreWholeNumbers() {
        var form = ScheduleForm(plan: Self.plan())
        for bad in ["", "-1", "1.5", "ten", "10000", "٣"] {
            form.daily = bad
            #expect(form.retention == .failure("Enter a whole number from 0 to 9999."), "\(bad)")
        }
    }

    @Test func retentionMustKeepSomething() {
        var form = ScheduleForm(plan: Self.plan())
        (form.hourly, form.daily, form.weekly, form.monthly) = ("0", "0", "0", "0")
        #expect(form.retention == .failure("Keep at least one snapshot: set one of these above 0."))
    }

    @Test func anIntervalSetElsewhereShowsTheNearestChoiceAtOrAbove() {
        var plan = Self.plan()
        plan.schedule = .interval(seconds: 3 * 3600)
        #expect(ScheduleForm(plan: plan).intervalHours == 4)
        plan.schedule = .interval(seconds: 48 * 3600)
        #expect(ScheduleForm(plan: plan).intervalHours == 24)
        plan.conditions.battery = .minimumPercent(35)
        #expect(ScheduleForm(plan: plan).battery == .minimumPercent(20))
    }

    @Test func titles() {
        #expect(ScheduleForm.title(hours: 1) == "Every hour")
        #expect(ScheduleForm.title(hours: 6) == "Every 6 hours")
        #expect(ScheduleForm.title(hours: 24) == "Once a day")
        #expect(ScheduleForm.title(battery: .minimumPercent(20)) == "Above 20%")
        #expect(ScheduleForm.title(battery: .minimumPercent(0)) == "Always")
        #expect(ScheduleForm.title(battery: .neverOnBattery) == "Never")
    }

    @Test func checkInURLIsOptionalAndHTTPS() {
        #expect(ScheduleForm.checkInProblem("") == nil)
        #expect(ScheduleForm.checkInProblem("  ") == nil)
        #expect(ScheduleForm.checkInProblem("https://hc-ping.com/0f1e2d3c") == nil)
        #expect(ScheduleForm.checkInProblem("http://healthchecks.local:8000/ping/x") == nil)
        #expect(ScheduleForm.checkInProblem("http://hc-ping.com/x") == "Use https:// for a check-in service outside your local network.")
        #expect(ScheduleForm.checkInProblem("hc-ping.com/x") == "The check-in URL is a web address starting with https://.")
        #expect(ScheduleForm.checkInProblem("ftp://x/y") == "The check-in URL is a web address starting with https://.")
    }

    @Test func theCheckInExplanationSaysWhy() {
        #expect(ScheduleForm.checkInExplanation.contains("off, broken or stolen"))
        #expect(ScheduleForm.checkInExplanation.contains("No off-Mac monitoring"))
    }
}
