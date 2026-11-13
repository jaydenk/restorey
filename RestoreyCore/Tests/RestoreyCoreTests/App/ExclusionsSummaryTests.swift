import Foundation
import Testing

@testable import RestoreyCore

@Suite struct ExclusionsSummaryTests {
    private static let home = URL(fileURLWithPath: "/Users/te[s]t")
    private static let identity = try! Identity(infoDictionary: [
        "RestoreyRootID": "com.jaydenkerr.restorey.dev",
        "RestoreyAgentLabel": "com.jaydenkerr.restorey.dev.agent",
        "RestoreyKeychainGroup": "ABCDE12345.com.jaydenkerr.restorey.dev",
        "RestoreyLogsName": "Restorey-Dev",
    ])

    private static func plan() -> Plan {
        Plan.newHotPlan(
            name: "Test", repository: .raw(repository: "/Volumes/B", environmentNames: []), origin: .created,
            hostLabel: "pepper", sources: [home.path],
            exclusions: DefaultExclusions.paths(home: home, identity: identity), now: Date(timeIntervalSince1970: 0))
    }

    @Test func theDefaultsGetTheMockupsLine() {
        #expect(ExclusionsSummary.line(plan: Self.plan(), home: Self.home, identity: Self.identity)
            == "Skipped by default: caches, Trash, node_modules, VM and disk images, iCloud files not on this Mac "
            + "(Time Machine's list, plus Backblaze's file types).")
    }

    @Test func aChangedListIsCounted() {
        var plan = Self.plan()
        plan.exclusions = ["**/node_modules"]
        plan.fileTypeExclusions = ["dmg", "iso"]
        #expect(ExclusionsSummary.line(plan: plan, home: Self.home, identity: Self.identity)
            == "Skipped: 1 folder, 2 file types, other file systems inside these folders and iCloud files not on this Mac.")
        plan.oneFileSystem = false
        plan.fileTypeExclusions = []
        #expect(ExclusionsSummary.line(plan: plan, home: Self.home, identity: Self.identity)
            == "Skipped: 1 folder, 0 file types and iCloud files not on this Mac.")
    }

    @Test func restoreysOwnFoldersAreTheLastTwoDefaults() {
        let own = DefaultExclusions.ownFolders(home: Self.home, identity: Self.identity)
        #expect(own == [
            "/Users/te\\[s\\]t/Library/Logs/Restorey-Dev",
            "/Users/te\\[s\\]t/Library/Application Support/com.jaydenkerr.restorey.dev",
        ])
        #expect(Array(DefaultExclusions.paths(home: Self.home, identity: Self.identity).suffix(2)) == own)
    }

    @Test func aPickedFolderMatchesOnlyItselfAndShowsWithATilde() {
        let pattern = DefaultExclusions.pattern(forFolder: "/Users/te[s]t/Movies/*raw*/")
        #expect(pattern == "/Users/te\\[s\\]t/Movies/\\*raw\\*")
        #expect(DefaultExclusions.displayPattern(pattern, home: Self.home) == "~/Movies/\\*raw\\*")
        #expect(DefaultExclusions.displayPattern("**/node_modules", home: Self.home) == "**/node_modules")
        #expect(DefaultExclusions.displayPattern("/Users/te\\[s\\]t", home: Self.home) == "~")
    }
}
