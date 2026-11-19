import Foundation
import Testing
@testable import RestoreyCore

/// A plan's repository folder and the sources that may not sit inside it (Task 1).
struct PlanTests {
    private static func raw(_ location: String) -> Repository { .raw(repository: location, environmentNames: []) }

    private static func plan(_ repository: Repository, sources: [String]) -> Plan {
        Plan.newHotPlan(
            name: "Home", repository: repository, origin: .created, hostLabel: "pepper", sources: sources,
            exclusions: [], now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func localFolderPathReadsLocalAndPlainPaths() {
        #expect(Self.raw("local:/Volumes/Disk/repo").localFolderPath == "/Volumes/Disk/repo")
        #expect(Self.raw("/Volumes/Disk/repo/").localFolderPath == "/Volumes/Disk/repo")
        #expect(Self.raw("b2:bucket:path").localFolderPath == nil)
        #expect(Self.raw("sftp:host:/x").localFolderPath == nil)
        #expect(Self.raw("../repo").localFolderPath == nil)
        let s3 = S3Location(
            provider: .b2, endpoint: URL(string: "https://s3.example.com")!, bucket: "bucket", prefix: "mac")
        #expect(Repository.s3(s3).localFolderPath == nil)
    }

    @Test func aSourceInsideTheRepositoryIsInvalid() {
        let plan = Self.plan(Self.raw("/Volumes/Disk/repo"), sources: ["/Volumes/Disk/repo/data"])
        #expect(plan.validationErrors().contains(.sourceInsideRepository("/Volumes/Disk/repo/data")))
    }

    @Test func aSourceContainingTheRepositoryIsValid() {
        let plan = Self.plan(Self.raw("/Volumes/Disk/repo"), sources: ["/Volumes/Disk"])
        #expect(!plan.validationErrors().contains(.sourceInsideRepository("/Volumes/Disk")))
        #expect(plan.validationErrors().isEmpty)
    }
}
