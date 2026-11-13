import Foundation
import Testing

@testable import RestoreyCore

@Suite struct SetupAdoptionTests {
    private static func plan(repository: Repository = .raw(repository: "/Volumes/Backup/restic", environmentNames: []))
        -> Plan
    {
        Plan.newHotPlan(
            name: "Test", repository: repository, origin: .created, hostLabel: "pepper", sources: ["/Users/me"],
            exclusions: [], now: Date(timeIntervalSince1970: 0))
    }

    private static let b2: Repository = .s3(S3Location(
        provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, bucket: "b", prefix: ""))

    // MARK: Summary

    @Test func summaryCountsSnapshotsAndMacs() {
        #expect(SetupAdoption.summary(AdoptReport(hosts: ["a", "b", "c"], latestPathsForHost: [], snapshotCount: 312))
            == "312 snapshots from 3 Macs")
        #expect(SetupAdoption.summary(AdoptReport(hosts: ["a"], latestPathsForHost: [], snapshotCount: 1))
            == "1 snapshot from 1 Mac")
        #expect(SetupAdoption.summary(AdoptReport(hosts: ["a", "b"], latestPathsForHost: [], snapshotCount: 1204))
            == "1,204 snapshots from 2 Macs")
        #expect(SetupAdoption.summary(AdoptReport(hosts: [], latestPathsForHost: [], snapshotCount: 0))
            == "No snapshots yet")
    }

    // MARK: Host label

    @Test func thisMacNamesListsEachNameOnceComputerNameFirst() {
        let names = SetupAdoption.thisMacNames(
            computerName: "pepper", localHostName: "pepper-2", hostName: "pepper.home.kerr.host")
        #expect(names == ["pepper", "pepper-2", "pepper.home.kerr.host", "pepper-2.local"])
        #expect(SetupAdoption.thisMacNames(computerName: " ", localHostName: nil, hostName: nil) == [])
    }

    @Test func hostLabelDefaultsToTheMatchingHostAsTheSnapshotsSpellIt() {
        let thisMac = ["pepper", "pepper-2", "pepper.home.kerr.host"]
        // The snapshots' spelling wins, so --host keeps adding to that group.
        #expect(SetupAdoption.defaultHostLabel(hosts: ["nas", "Pepper"], thisMac: thisMac) == "Pepper")
        // restic's own default host, the Unix host name.
        #expect(SetupAdoption.defaultHostLabel(hosts: ["pepper.home.kerr.host"], thisMac: thisMac)
            == "pepper.home.kerr.host")
        // Earlier names in `thisMac` win when several match.
        #expect(SetupAdoption.defaultHostLabel(hosts: ["pepper-2", "pepper"], thisMac: thisMac) == "pepper")
    }

    @Test func hostLabelWithNoMatchIsThisMacsName() {
        #expect(SetupAdoption.defaultHostLabel(hosts: ["nas", "laptop"], thisMac: ["pepper"]) == "pepper")
        #expect(SetupAdoption.defaultHostLabel(hosts: [], thisMac: []) == "Mac")
    }

    @Test func hostChoicesAddThisMacWhenNoHostHasItsName() {
        #expect(SetupAdoption.hostChoices(hosts: ["laptop", "nas"], thisMac: ["pepper"]) == ["laptop", "nas", "pepper"])
        #expect(SetupAdoption.hostChoices(hosts: ["Pepper", "nas"], thisMac: ["pepper"]) == ["Pepper", "nas"])
    }

    // MARK: Plan defaults

    @Test func adoptedPlanNeverPrunesAndForgetsDaily() {
        let plan = SetupAdoption.adopted(SetupAdoptionTests.plan(repository: Self.b2), hostLabel: "Pepper")
        #expect(plan.origin == .adopted)
        #expect(plan.hostLabel == "Pepper")
        #expect(plan.pruneEnabled == false)
        #expect(plan.forgetCadence == .daily)
        #expect(plan.packSizeMiB == nil)
    }

    @Test func createdPlanGetsNewHotPlansDefaultsBack() {
        let adopted = SetupAdoption.adopted(Self.plan(repository: Self.b2), hostLabel: "x")
        let created = SetupAdoption.created(adopted)
        let fresh = Self.plan(repository: Self.b2)
        #expect(created.origin == .created)
        #expect(created.pruneEnabled == fresh.pruneEnabled)
        #expect(created.forgetCadence == fresh.forgetCadence)
        #expect(created.packSizeMiB == 64)
        #expect(SetupAdoption.created(Self.plan()).packSizeMiB == nil)
    }

    // MARK: Sources

    @Test func sourcesArePrefilledFromTheLatestSnapshotForThisHost() {
        let report = AdoptReport(hosts: ["pepper"], latestPathsForHost: ["/Users/me", "/Volumes/Photos/"], snapshotCount: 4)
        #expect(SetupAdoption.prefilledSources(report, current: ["/Users/me"]) == ["/Users/me", "/Volumes/Photos"])
    }

    @Test func sourcesStayWhenThisHostHasNoSnapshot() {
        let report = AdoptReport(hosts: ["nas"], latestPathsForHost: [], snapshotCount: 4)
        #expect(SetupAdoption.prefilledSources(report, current: ["/Users/me"]) == ["/Users/me"])
        // Anything restic recorded that isn't absolute (it never should be) isn't taken.
        let odd = AdoptReport(hosts: ["pepper"], latestPathsForHost: ["relative"], snapshotCount: 1)
        #expect(SetupAdoption.prefilledSources(odd, current: ["/Users/me"]) == ["/Users/me"])
    }

    // MARK: New group warning

    @Test func warnsWhenNoSnapshotHasTheHostLabel() throws {
        let report = AdoptReport(hosts: ["nas"], latestPathsForHost: [], snapshotCount: 4)
        let warning = try #require(SetupAdoption.newGroupWarning(hostLabel: "pepper", sources: nil, report: report))
        #expect(warning.hasPrefix("No snapshots here are from “pepper”, so the first backup starts a new snapshot group"))
        #expect(warning.hasSuffix("."))
    }

    @Test func warnsWhenTheSourcesDifferFromTheLatestSnapshot() throws {
        let report = AdoptReport(hosts: ["pepper"], latestPathsForHost: ["/Users/me"], snapshotCount: 4)
        let warning = try #require(SetupAdoption.newGroupWarning(
            hostLabel: "pepper", sources: ["/Users/me", "/Volumes/Photos"], report: report))
        #expect(warning.hasPrefix("These folders differ from the latest snapshot from “pepper”"))
    }

    @Test func noWarningWhenTheFirstBackupContinuesTheGroup() {
        let report = AdoptReport(hosts: ["pepper"], latestPathsForHost: ["/Users/me/", "/Volumes/Photos"], snapshotCount: 4)
        // Order and a trailing slash don't make a new group: restic compares the paths as a set.
        #expect(SetupAdoption.newGroupWarning(
            hostLabel: "pepper", sources: ["/Volumes/Photos", "/Users/me"], report: report) == nil)
        // The host matches and the sources aren't chosen yet.
        #expect(SetupAdoption.newGroupWarning(hostLabel: "pepper", sources: nil, report: report) == nil)
        // An empty repository has no group to continue.
        let empty = AdoptReport(hosts: [], latestPathsForHost: [], snapshotCount: 0)
        #expect(SetupAdoption.newGroupWarning(hostLabel: "pepper", sources: ["/Users/me"], report: empty) == nil)
    }
}
