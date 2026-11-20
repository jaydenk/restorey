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

    /// Seen live 20 Nov 2026: the picker stored `/tmp/x`, the typed repository kept `/private/tmp/x/repo`, and the fixed row vanished.
    @Test func theRepositoryRowMatchesAcrossPrivateSpellings() {
        let repository = Repository.raw(repository: "/private/tmp/x/repo", environmentNames: [])
        #expect(ExclusionsSummary.repositoryRow(repository: repository, sources: ["/tmp/x"]) == "/private/tmp/x/repo")
    }

    @Test func theDefaultsGetTheMockupsLine() {
        #expect(ExclusionsSummary.line(plan: Self.plan(), home: Self.home, identity: Self.identity)
            == "Skipped by default: caches, Trash, node_modules, VM and disk images, iCloud files not on this Mac, "
            + "items apps mark as not for backup (Time Machine’s list, plus Backblaze’s file types).")
    }

    /// Task 15c: the Folders tab (What until Task 17c) has its own line for marked items, with a count, so its summary leaves them out.
    @Test func theMarkedItemsCanBeLeftToTheirOwnLine() {
        #expect(ExclusionsSummary.line(plan: Self.plan(), home: Self.home, identity: Self.identity, mentionsMarkedItems: false)
            == "Skipped by default: caches, Trash, node_modules, VM and disk images, iCloud files not on this Mac "
            + "(Time Machine’s list, plus Backblaze’s file types).")
        var plan = Self.plan()
        plan.skipsItemsMarkedNotForBackup = false
        #expect(ExclusionsSummary.line(plan: plan, home: Self.home, identity: Self.identity)
            == "Skipped: \(plan.exclusions.count) folders, \(plan.fileTypeExclusions.count) file types, other file systems "
            + "inside these folders and iCloud files not on this Mac.")
    }

    @Test func aChangedListIsCounted() {
        var plan = Self.plan()
        plan.exclusions = ["**/node_modules"]
        plan.fileTypeExclusions = ["dmg", "iso"]
        #expect(ExclusionsSummary.line(plan: plan, home: Self.home, identity: Self.identity)
            == "Skipped: 1 folder, 2 file types, other file systems inside these folders, iCloud files not on this Mac "
            + "and items apps mark as not for backup.")
        plan.oneFileSystem = false
        plan.fileTypeExclusions = []
        #expect(ExclusionsSummary.line(plan: plan, home: Self.home, identity: Self.identity, mentionsMarkedItems: false)
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

    // v0.1.1, Task 2: the Exclusions sheet's fixed row for the plan's own repository.

    @Test func aLocalRepositoryInsideASourceGetsTheFixedRow() {
        let repository = Repository.raw(repository: "/Volumes/Disk/repo", environmentNames: [])
        #expect(ExclusionsSummary.repositoryRow(repository: repository, sources: ["/Volumes/Disk"]) == "/Volumes/Disk/repo")
    }

    /// Round 2: the sheet asks on every render, so this compares by path and never follows a link (the agent excludes
    /// both spellings of the folder anyway): a source that is a link to the repository's parent gets no row.
    @Test func theRowIsDecidedByPathWithoutFollowingLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ExclusionsSummaryTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let disk = root.appendingPathComponent("disk")
        try fm.createDirectory(at: disk.appendingPathComponent("repo"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: disk)
        let repository = Repository.raw(repository: disk.appendingPathComponent("repo").path, environmentNames: [])
        #expect(ExclusionsSummary.repositoryRow(repository: repository, sources: [link.path]) == nil)
        #expect(ExclusionsSummary.repositoryRow(repository: repository, sources: [disk.path]) != nil)
    }

    @Test func aRepositoryOutsideEverySourceGetsNoRow() {
        let repository = Repository.raw(repository: "/Volumes/Backups/repo", environmentNames: [])
        #expect(ExclusionsSummary.repositoryRow(repository: repository, sources: ["/Volumes/Backup", "/Users/me"]) == nil)
    }

    @Test func aRepositoryThatIsNotALocalFolderOrNotYetChosenGetsNoRow() {
        let remote = Repository.raw(repository: "sftp:host:/repo", environmentNames: [])
        #expect(ExclusionsSummary.repositoryRow(repository: remote, sources: ["/"]) == nil)
        #expect(ExclusionsSummary.repositoryRow(repository: nil, sources: ["/"]) == nil)
    }
}
