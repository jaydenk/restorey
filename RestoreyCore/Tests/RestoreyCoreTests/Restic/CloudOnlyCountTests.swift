import Foundation
import Testing
@testable import RestoreyCore

/// Task 15b: the scoping, the counting over a fake tree, the bound, the stored field and the words.
struct CloudOnlyCountTests {
    private static let home = "/Users/me"
    private static let drive = "/Users/me/Library/Mobile Documents"
    private static let storage = "/Users/me/Library/CloudStorage"
    private static let en = Locale(identifier: "en_AU")

    // MARK: Scope

    @Test func theHomeFolderReachesBothRoots() {
        let roots = CloudOnlyScope.roots(home: Self.home, sources: ["/Users/me"], exclusions: [])
        #expect(roots == [
            CloudOnlyRoot(path: Self.drive, isOtherProvider: false),
            CloudOnlyRoot(path: Self.storage, isOtherProvider: true),
        ])
    }

    @Test func theWholeDiskReachesBothRoots() {
        let both = [
            CloudOnlyRoot(path: Self.drive, isOtherProvider: false),
            CloudOnlyRoot(path: Self.storage, isOtherProvider: true),
        ]
        #expect(CloudOnlyScope.roots(home: Self.home, sources: ["/"], exclusions: []) == both)
        // An exclusion of "/" itself, or of a folder above the roots, still applies.
        #expect(CloudOnlyScope.roots(home: Self.home, sources: ["/"], exclusions: ["/"]).isEmpty)
        #expect(CloudOnlyScope.roots(home: Self.home, sources: ["/"], exclusions: ["/Users"]).isEmpty)
    }

    @Test func aSourceInsideARootIsWalkedAlone() {
        let source = Self.drive + "/com~apple~CloudDocs/Work"
        #expect(CloudOnlyScope.roots(home: Self.home, sources: [source], exclusions: [])
            == [CloudOnlyRoot(path: source, isOtherProvider: false)])
        let other = Self.storage + "/Dropbox/Work"
        #expect(CloudOnlyScope.roots(home: Self.home, sources: [other], exclusions: [])
            == [CloudOnlyRoot(path: other, isOtherProvider: true)])
    }

    @Test func anUnrelatedSourceReachesNothing() {
        #expect(CloudOnlyScope.roots(home: Self.home, sources: ["/Users/me/Documents", "/Volumes/Photos"], exclusions: []).isEmpty)
        // A sibling that only shares a name prefix isn't inside the root.
        #expect(CloudOnlyScope.roots(home: Self.home, sources: [Self.drive + " Old"], exclusions: []).isEmpty)
    }

    @Test func overlappingSourcesAreWalkedOnce() {
        let inside = Self.drive + "/com~apple~CloudDocs"
        let roots = CloudOnlyScope.roots(
            home: Self.home, sources: [inside, "/Users/me", inside + "/Work", "/Users/me/"], exclusions: [])
        #expect(roots.map(\.path) == [Self.drive, Self.storage])
    }

    @Test func aLiteralExclusionEqualToARootOrAboveItDropsIt() {
        let roots = CloudOnlyScope.roots(home: Self.home, sources: ["/Users/me"], exclusions: [Self.drive, "/Users/me/Library"])
        #expect(roots.isEmpty)
        #expect(CloudOnlyScope.roots(home: Self.home, sources: [Self.drive + "/A"], exclusions: [Self.drive + "/A"]).isEmpty)
        // A glob is ignored, and a folder deeper than the root doesn't remove it.
        #expect(CloudOnlyScope.roots(home: Self.home, sources: ["/Users/me"], exclusions: ["**/Mobile*", Self.drive + "/A"]).count == 2)
    }

    @Test func literalPathsUndoEscapesAndRefuseGlobs() {
        #expect(CloudOnlyScope.literalPath("/Users/me/Library/Mobile Documents/.Trash") == "/Users/me/Library/Mobile Documents/.Trash")
        #expect(CloudOnlyScope.literalPath("/Users/a\\[b\\]/x") == "/Users/a[b]/x")
        #expect(CloudOnlyScope.literalPath("/Users/me/*/Caches") == nil)
        #expect(CloudOnlyScope.literalPath("**/node_modules") == nil)
        #expect(CloudOnlyScope.literalPath("node_modules") == nil)
    }

    // MARK: Counting over a fake tree

    /// A tree in memory that honours `skipChildren` and `stop`, and records every path it yielded.
    private final class FakeTree: CloudOnlyWalking, @unchecked Sendable {
        indirect enum Node {
            case file(String, dataless: Bool = false)
            case link(String, dataless: Bool = false)
            case folder(String, dataless: Bool = false, [Node])
        }

        let roots: [String: [Node]]
        private(set) var yielded: [String] = []

        init(_ roots: [String: [Node]]) { self.roots = roots }

        func walk(root: String, visit: (CloudOnlyEntry) -> CloudOnlyAction) {
            _ = go(root, nodes: roots[root] ?? [], visit: visit)
        }

        /// False once the walk is stopped.
        private func go(_ path: String, nodes: [Node], visit: (CloudOnlyEntry) -> CloudOnlyAction) -> Bool {
            yielded.append(path)
            switch visit(CloudOnlyEntry(path: path, isDirectory: true, isDataless: false)) {
            case .stop: return false
            case .skipChildren: return true
            case .descend: break
            }
            return children(path, nodes, visit)
        }

        private func children(_ parent: String, _ nodes: [Node], _ visit: (CloudOnlyEntry) -> CloudOnlyAction) -> Bool {
            for node in nodes {
                switch node {
                case .file(let name, let dataless):
                    yielded.append("\(parent)/\(name)")
                    if visit(CloudOnlyEntry(path: "\(parent)/\(name)", isDirectory: false, isDataless: dataless)) == .stop { return false }
                case .link(let name, let dataless):
                    yielded.append("\(parent)/\(name)")
                    let entry = CloudOnlyEntry(path: "\(parent)/\(name)", isDirectory: false, isSymlink: true, isDataless: dataless)
                    if visit(entry) == .stop { return false }
                case .folder(let name, let dataless, let kids):
                    let path = "\(parent)/\(name)"
                    yielded.append(path)
                    switch visit(CloudOnlyEntry(path: path, isDirectory: true, isDataless: dataless)) {
                    case .stop: return false
                    case .skipChildren: continue
                    case .descend: if !children(path, kids, visit) { return false }
                    }
                }
            }
            return true
        }
    }

    private static let driveRoot = CloudOnlyRoot(path: drive, isOtherProvider: false)
    private static let storageRoot = CloudOnlyRoot(path: storage, isOtherProvider: true)

    @Test func aDatalessFileCountsAndALocalOneDoesNot() {
        let tree = FakeTree([Self.drive: [.file("a", dataless: true), .file("b"), .file("c", dataless: true)]])
        let result = CloudOnlyCounter(walker: tree, entryLimit: 100, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: [])
        #expect(result == .counted(CloudOnlyCount(skipped: 2, includesOtherProviders: false)))
    }

    @Test func aDatalessFolderCountsOnceAndItsChildrenAreNeverVisited() {
        let tree = FakeTree([Self.drive: [
            .folder("Cloud", dataless: true, [.file("x", dataless: true), .file("y", dataless: true)]),
            .folder("Local", [.file("z", dataless: true)]),
        ]])
        let result = CloudOnlyCounter(walker: tree, entryLimit: 100, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: [])
        #expect(result == .counted(CloudOnlyCount(skipped: 2, includesOtherProviders: false)))
        #expect(!tree.yielded.contains { $0.hasPrefix(Self.drive + "/Cloud/") })
    }

    @Test func aSymlinkIsNeitherCountedNorFollowed() {
        let tree = FakeTree([Self.drive: [.link("alias", dataless: true), .link("other")]])
        let result = CloudOnlyCounter(walker: tree, entryLimit: 100, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: [])
        #expect(result == .counted(CloudOnlyCount(skipped: 0, includesOtherProviders: false)))
    }

    @Test func anExcludedSubtreeIsSkipped() {
        let tree = FakeTree([Self.drive: [
            .folder(".Trash", [.file("gone", dataless: true)]), .folder("Keep", [.file("k", dataless: true)]),
        ]])
        let result = CloudOnlyCounter(walker: tree, entryLimit: 100, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: [Self.drive + "/.Trash", "**/Keep", "/Users/me/*/x"])
        #expect(result == .counted(CloudOnlyCount(skipped: 1, includesOtherProviders: false)))
        #expect(!tree.yielded.contains(Self.drive + "/.Trash/gone"))
    }

    @Test func anExcludedDatalessFolderIsNotCounted() {
        let tree = FakeTree([Self.drive: [.folder(".Trash", dataless: true, []), .folder("Other", dataless: true, [])]])
        let result = CloudOnlyCounter(walker: tree, entryLimit: 100, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: [Self.drive + "/.Trash"])
        #expect(result == .counted(CloudOnlyCount(skipped: 1, includesOtherProviders: false)))
    }

    @Test func cloudStorageSwitchesTheWording() {
        let tree = FakeTree([
            Self.drive: [.file("a", dataless: true)], Self.storage: [.file("b", dataless: true)],
        ])
        let counter = CloudOnlyCounter(walker: tree, entryLimit: 100, isOutOfTime: { false })
        #expect(counter.count(roots: [Self.driveRoot], exclusions: [])
            == .counted(CloudOnlyCount(skipped: 1, includesOtherProviders: false)))
        #expect(counter.count(roots: [Self.driveRoot, Self.storageRoot], exclusions: [])
            == .counted(CloudOnlyCount(skipped: 2, includesOtherProviders: true)))
    }

    @Test func noRootsIsAZeroCountNotAGiveUp() {
        let result = CloudOnlyCounter(walker: FakeTree([:]), entryLimit: 100, isOutOfTime: { false }).count(roots: [], exclusions: [])
        #expect(result == .counted(CloudOnlyCount(skipped: 0, includesOtherProviders: false)))
    }

    // MARK: The bound

    @Test func moreEntriesThanTheLimitGivesUp() {
        let files = (0..<50).map { FakeTree.Node.file("f\($0)", dataless: true) }
        let tree = FakeTree([Self.drive: files])
        #expect(CloudOnlyCounter(walker: tree, entryLimit: 10, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: []) == .gaveUp)
        // The walk stopped at the limit rather than visiting everything.
        #expect(tree.yielded.count <= 11)
        #expect(CloudOnlyCounter(walker: tree, entryLimit: 51, isOutOfTime: { false })
            .count(roots: [Self.driveRoot], exclusions: []) == .counted(CloudOnlyCount(skipped: 50, includesOtherProviders: false)))
    }

    @Test func runningOutOfTimeGivesUp() {
        let files = (0..<600).map { FakeTree.Node.file("f\($0)") }
        let tree = FakeTree([Self.drive: files])
        #expect(CloudOnlyCounter(walker: tree, entryLimit: 1_000_000, isOutOfTime: { true })
            .count(roots: [Self.driveRoot], exclusions: []) == .gaveUp)
    }

    // MARK: The record

    private func record(_ count: CloudOnlyCount?) -> RunRecord {
        RunRecord(
            id: UUID(), planID: UUID(), operation: .backup, trigger: .scheduled, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060), outcome: .success(snapshotID: "abc"), summary: nil, logFile: "",
            cloudOnlySkipped: count)
    }

    @Test func aRecordRoundTripsTheCount() throws {
        let original = record(CloudOnlyCount(skipped: 4834, includesOtherProviders: true))
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.cloudOnlySkipped == CloudOnlyCount(skipped: 4834, includesOtherProviders: true))
    }

    @Test func aRecordWithoutACountOmitsTheKeyAndOldJSONStillDecodes() throws {
        let data = try JSONEncoder().encode(record(nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["cloudOnlySkipped"] == nil)
        #expect(try JSONDecoder().decode(RunRecord.self, from: data).cloudOnlySkipped == nil)
    }

    // MARK: Words

    @Test func theWordsFollowTheCountAndTheOrigin() {
        func summary(_ n: Int, _ other: Bool = false) -> String? {
            CloudOnlyText.summary(CloudOnlyCount(skipped: n, includesOtherProviders: other), locale: Self.en)
        }
        #expect(summary(4834) == "4,834 iCloud files not on this Mac skipped")
        #expect(summary(1) == "1 iCloud file not on this Mac skipped")
        #expect(summary(2, true) == "2 cloud files not on this Mac skipped")
        #expect(summary(0) == nil)
        #expect(CloudOnlyText.summary(nil, locale: Self.en) == nil)
        #expect(CloudOnlyText.sentence(CloudOnlyCount(skipped: 4834, includesOtherProviders: false), locale: Self.en)
            == "4,834 iCloud files not on this Mac were skipped.")
        #expect(CloudOnlyText.sentence(CloudOnlyCount(skipped: 1, includesOtherProviders: true), locale: Self.en)
            == "1 cloud file not on this Mac was skipped.")
        #expect(CloudOnlyText.sentence(CloudOnlyCount(skipped: 0, includesOtherProviders: false), locale: Self.en) == nil)
        #expect(CloudOnlyText.howTo
            == "To include them, download them in Finder (Download Now) or turn off Optimise Mac Storage.")
    }

    @Test func historyAppendsTheCountToABackupRowOnly() {
        let backup = record(CloudOnlyCount(skipped: 4834, includesOtherProviders: false))
        let row = HistoryPresentation.row(
            backup, planNames: [:], now: backup.endedAt, calendar: .init(identifier: .gregorian), locale: Self.en)
        #expect(row.detail?.contains("4,834 iCloud files not on this Mac skipped") == true)
        #expect(row.kind == .success)
        var none = backup
        none.cloudOnlySkipped = nil
        let plain = HistoryPresentation.row(
            none, planNames: [:], now: backup.endedAt, calendar: .init(identifier: .gregorian), locale: Self.en)
        #expect(plain.detail?.contains("iCloud") != true)
    }

    @Test func theOverviewShowsAQuietNoteForTheLastBackup() {
        let plan = Plan.newHotPlan(
            name: "P", repository: .raw(repository: "/r", environmentNames: []), origin: .created, hostLabel: "mac",
            sources: ["/Users/me"], exclusions: [], now: Date(timeIntervalSince1970: 1_800_000_000))
        func note(_ count: CloudOnlyCount?, alerts: [AlertCondition] = []) -> PlanOverview.CloudOnlyNote? {
            var backup = record(count)
            backup.planID = plan.id
            let status = PlanStatus(
                plan: plan, phase: .idle, lastRecord: backup, nextRunAt: nil, alerts: alerts, lastBackup: backup,
                latestBackupRecord: backup, latestBackupVerdict: backup)
            return MenuPresentation.overview(
                planID: plan.id, health: .healthy,
                status: AgentStatus(plans: [status], configError: nil, fdaMissing: false, generatedAt: backup.endedAt),
                notificationsAuthorised: true, rates: [:], now: backup.endedAt, calendar: .init(identifier: .gregorian),
                locale: Self.en)?.cloudOnlyNote
        }
        #expect(note(CloudOnlyCount(skipped: 4834, includesOtherProviders: false))
            == .init(line: "4,834 iCloud files not on this Mac were skipped.", howTo: CloudOnlyText.howTo))
        #expect(note(CloudOnlyCount(skipped: 0, includesOtherProviders: false)) == nil)
        #expect(note(nil) == nil)
        #expect(note(CloudOnlyCount(skipped: 3, includesOtherProviders: false), alerts: [.backupFailed]) == nil)
    }
}
