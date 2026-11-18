import Darwin
import Foundation
import Synchronization
import Testing
@testable import RestoreyCore

/// Task 15c: items apps mark as not for backup (Time Machine's per-item attribute). The collapse, the exclude-file
/// text, the scan over a fake index, the stored fields, the words, and the real `getxattr` check on a temp folder.
struct MarkedNotForBackupTests {
    private static let home = "/Users/me"
    private static let en = Locale(identifier: "en_AU")

    // MARK: Collapse

    private func collapse(
        _ marked: [String], sources: [String] = [home], exclusions: [String] = [], backUpAnyway: [String] = []
    ) -> [String] {
        MarkedNotForBackup.collapse(marked, sources: sources, exclusions: exclusions, backUpAnyway: backUpAnyway)
    }

    @Test func anItemInsideAnotherIsDropped() {
        #expect(collapse([
            "/Users/me/Library/App/Cache/inner", "/Users/me/Library/App/Cache", "/Users/me/Library/App/Cache/inner/deeper",
        ]) == ["/Users/me/Library/App/Cache"])
        // A sibling whose name only starts the same is not inside.
        #expect(collapse(["/Users/me/a", "/Users/me/ab"]) == ["/Users/me/a", "/Users/me/ab"])
    }

    @Test func duplicatesAndTrailingSlashesCollapse() {
        #expect(collapse(["/Users/me/x", "/Users/me/x", "/Users/me/x/"]) == ["/Users/me/x"])
    }

    @Test func anItemOutsideEverySourceIsDropped() {
        #expect(collapse(["/Users/other/x", "/Volumes/Data/y"], sources: ["/Users/me", "/Volumes/Data"]) == ["/Volumes/Data/y"])
        // The whole disk reaches everything, /private included as Spotlight reports it (not standardised to /var).
        #expect(collapse(["/private/var/folders/x"], sources: ["/"]) == ["/private/var/folders/x"])
    }

    @Test func aSourceItselfOrAFolderAboveOneIsNeverSkipped() {
        // The person chose that folder: skipping it would skip the whole source.
        #expect(collapse(["/Users/me/Work", "/Users/me"], sources: ["/Users/me/Work"]).isEmpty)
        #expect(collapse(["/Users/me", "/Users/me/Work/build"], sources: ["/Users/me"]) == ["/Users/me/Work/build"])
    }

    @Test func anItemInsideALiteralExclusionIsDropped() {
        let exclusions = [
            DefaultExclusions.pattern(forFolder: "/Users/me/Library/Caches"),
            DefaultExclusions.pattern(forFolder: "/Users/me/odd[1]"),
            // A glob is ignored: it says nothing exact about which paths it covers.
            "/Users/me/Library/Containers/*/Data/Library/Caches",
            "**/node_modules",
        ]
        #expect(collapse([
            "/Users/me/Library/Caches", "/Users/me/Library/Caches/com.app/x", "/Users/me/odd[1]/y",
            "/Users/me/Library/Containers/com.a/Data/Library/Caches/z", "/Users/me/p/node_modules/q",
        ], exclusions: exclusions) == [
            "/Users/me/Library/Containers/com.a/Data/Library/Caches/z", "/Users/me/p/node_modules/q",
        ])
    }

    @Test func aBackUpAnywayEntryKeepsItselfAndEverythingUnderIt() {
        let marked = ["/Users/me/Lightroom/Previews.lrdata", "/Users/me/Lightroom/Previews.lrdata/inner", "/Users/me/Teams"]
        #expect(collapse(marked, backUpAnyway: ["/Users/me/Lightroom/Previews.lrdata"]) == ["/Users/me/Teams"])
        // An entry above an item covers it too.
        #expect(collapse(marked, backUpAnyway: ["/Users/me/Lightroom"]) == ["/Users/me/Teams"])
    }

    @Test func aNestedItemReappearsWhenItsParentIsBackedUpAnyway() {
        // Only the outer item is listed while it is skipped; backing it up anyway means everything under it.
        let marked = ["/Users/me/A", "/Users/me/A/B"]
        #expect(collapse(marked) == ["/Users/me/A"])
        #expect(collapse(marked, backUpAnyway: ["/Users/me/A"]).isEmpty)
    }

    @Test func anItemHoldingABackUpAnywayEntryIsNotSkipped() {
        // Excluding the outer folder would exclude the entry the person asked for, so the outer one is backed up.
        #expect(collapse(["/Users/me/A", "/Users/me/A/B/C"], backUpAnyway: ["/Users/me/A/B"]).isEmpty)
    }

    // MARK: The exclude file

    @Test func anOrdinaryPathIsWrittenAsItIs() {
        #expect(MarkedNotForBackup.excludeLine(for: "/Users/me/Library/App Data/x.db") == "/Users/me/Library/App Data/x.db")
    }

    @Test func globCharactersAreEscaped() {
        #expect(MarkedNotForBackup.excludeLine(for: #"/Users/me/a*b?c[d]e\f"#) == #"/Users/me/a\*b\?c\[d\]e\\f"#)
    }

    /// Review I1: a glob character, `\` or `$` followed by a combining mark is one Swift `Character` with it, but restic
    /// (Go) reads runes, so escaping must work on Unicode scalars.
    @Test func escapingWorksOnScalarsNotGraphemeClusters() {
        let mark = "\u{0301}"
        for special in ["[", "]", "*", "?", "\\"] {
            let escaped = DefaultExclusions.escapedGlob("/a/x\(special)\(mark)y")
            #expect(Array(escaped.unicodeScalars) == Array("/a/x\\\(special)\(mark)y".unicodeScalars), "\(special)")
        }
        let line = MarkedNotForBackup.excludeLine(for: "/a/b[\(mark)c*\(mark)d$\(mark)e?\(mark)")
        #expect(line.map { Array($0.unicodeScalars) }
            == Array("/a/b\\[\(mark)c\\*\(mark)d$$\(mark)e\\?\(mark)".unicodeScalars))
        // A folder the person picks is escaped the same way.
        #expect(Array(DefaultExclusions.pattern(forFolder: "/a/x*\(mark)").unicodeScalars)
            == Array("/a/x\\*\(mark)".unicodeScalars))
        // A slash followed by a mark still separates components: an empty one is caught.
        #expect(MarkedNotForBackup.excludeLine(for: "/a//\(mark)b") == nil)
    }

    @Test func aDollarIsDoubledSoResticNeverExpandsIt() {
        // restic 0.19.1 readPatternsFromFiles runs os.Expand on each line: `$$` is a literal `$`.
        #expect(MarkedNotForBackup.excludeLine(for: "/Users/me/$HOME/a$") == "/Users/me/$$HOME/a$$")
        #expect(MarkedNotForBackup.excludeLine(for: "/Users/me/${X}") == "/Users/me/$${X}")
    }

    @Test func aHashIsKeptBecauseNoLineStartsWithOne() {
        // Only a line that starts with `#` is a comment, and every line starts with `/`.
        #expect(MarkedNotForBackup.excludeLine(for: "/Users/me/#notes") == "/Users/me/#notes")
        #expect(MarkedNotForBackup.excludeLine(for: "#relative") == nil)
    }

    @Test func pathsThatCantBeWrittenExactlyAreNotSkipped() {
        // A newline or carriage return would split or shorten the line; trailing white space is trimmed.
        for path in [
            "/Users/me/a\nb", "/Users/me/a\rb", "/Users/me/trailing ", "/Users/me/tab\t", "/Users/me/nbsp\u{00A0}",
            "/Users/me/a//b", "/Users/me/./b", "/Users/me/../b", "relative/path", "",
            "/Users/me/" + String(repeating: "x", count: 70_000),
        ] {
            #expect(MarkedNotForBackup.excludeLine(for: path) == nil, "\(path.debugDescription)")
        }
        // White space inside a name is fine, and so is a combining mark after a space (not trimmed by Go's TrimSpace).
        #expect(MarkedNotForBackup.excludeLine(for: "/Users/me/a b") == "/Users/me/a b")
        #expect(MarkedNotForBackup.excludeLine(for: "/Users/me/a \u{0301}") == "/Users/me/a \u{0301}")
    }

    @Test func theFileListsOneLinePerPathAndSaysWhatItLeftOut() {
        let file = MarkedNotForBackup.excludeFile(["/Users/me/a", "/Users/me/b\nc", "/Users/me/$d"])
        #expect(file.text == "/Users/me/a\n/Users/me/$$d\n")
        #expect(file.written == ["/Users/me/a", "/Users/me/$d"])
        #expect(file.unrepresentable == ["/Users/me/b\nc"])
        #expect(MarkedNotForBackup.excludeFile([]).text.isEmpty)
    }

    // MARK: The scan

    /// Spotlight's answer, and which paths still carry the attribute.
    final class FakeIndex: MarkedItemsFinding, Sendable {
        let answer: MarkedItemsQuery
        let stillMarked: Set<String>
        let asked = Mutex<[[String]]>([])
        let gate = OneOutstandingGate()

        init(_ answer: MarkedItemsQuery, stillMarked: Set<String>) {
            self.answer = answer
            self.stillMarked = stillMarked
        }

        func query(scopes: [String], limit: Int) -> MarkedItemsQuery {
            asked.withLock { $0.append(scopes) }
            return answer
        }

        func isMarked(_ path: String) -> Bool { stillMarked.contains(path) }
    }

    @Test func aStaleIndexEntryIsDropped() {
        let index = FakeIndex(.found(["/Users/me/a", "/Users/me/gone"]), stillMarked: ["/Users/me/a"])
        let scan = MarkedItemsScan(finder: index, limit: 100, isOutOfTime: { false })
        #expect(scan.run(sources: ["/Users/me/"]) == .found(["/Users/me/a"]))
        #expect(index.asked.withLock { $0 } == [["/Users/me"]])
    }

    @Test func tooManyResultsGiveUp() {
        let many = (0...100).map { "/Users/me/\($0)" }
        let index = FakeIndex(.found(many), stillMarked: Set(many))
        #expect(MarkedItemsScan(finder: index, limit: 100, isOutOfTime: { false }).run(sources: ["/Users/me"]) == .gaveUp)
        #expect(MarkedItemsScan(finder: index, limit: 101, isOutOfTime: { false }).run(sources: ["/Users/me"])
            == .found(many))
    }

    @Test func aFailedQueryOrRunningOutOfTimeGivesUp() {
        let failing = FakeIndex(.failed, stillMarked: [])
        #expect(MarkedItemsScan(finder: failing, limit: 100, isOutOfTime: { false }).run(sources: ["/Users/me"]) == .gaveUp)
        let found = FakeIndex(.found(["/Users/me/a"]), stillMarked: ["/Users/me/a"])
        #expect(MarkedItemsScan(finder: found, limit: 100, isOutOfTime: { true }).run(sources: ["/Users/me"]) == .gaveUp)
    }

    @Test func noSourcesAskNothing() {
        let index = FakeIndex(.found(["/x"]), stillMarked: ["/x"])
        #expect(MarkedItemsScan(finder: index, limit: 100, isOutOfTime: { false }).run(sources: []) == .found([]))
        #expect(index.asked.withLock { $0 }.isEmpty)
    }

    /// A query held until after the look has returned: the deadline decides. The same under GCD starvation is
    /// `GlobalQueueStarvationTests`, run on its own.
    @Test func theDeadlineWinsOverAStuckQuery() async {
        let held = Held()
        #expect(await MarkedItemsScan.offPool(finder: held, sources: ["/Users/me"], deadline: 0.1) == .gaveUp)
        held.release.signal()
    }

    /// A deadline these tests can't reach: they are not about the deadline, so a slow runner must not be able to pass it.
    /// The tests that are about it pass a tiny one and hold the query past it.
    static let unreachable: TimeInterval = 3600

    /// A query that blocks until the test lets it go, counting how often it was asked.
    final class Held: MarkedItemsFinding, Sendable {
        let gate = OneOutstandingGate()
        let release = DispatchSemaphore(value: 0)
        let asked = Mutex(0)
        func query(scopes: [String], limit: Int) -> MarkedItemsQuery {
            asked.withLock { $0 += 1 }
            release.wait()
            return .found(["/Users/me/a"])
        }
        func isMarked(_ path: String) -> Bool { true }
    }

    /// Review I2: a hung Spotlight leaves at most one blocked thread. While a look that has outlived its deadline is
    /// still outstanding, the next gives up at once without asking; once it returns, looks run again.
    @Test func aStuckLookIsNotJoinedByAnother() async {
        let held = Held()
        #expect(await MarkedItemsScan.offPool(finder: held, sources: ["/Users/me"], deadline: 0.1) == .gaveUp)
        // The deadline can win before the scan's thread has even reached the query on a busy Mac: wait for it to be
        // asked (and stuck), so the next look meets a query really hung.
        while held.asked.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        let started = ContinuousClock.now
        // Waiting for the stuck look would take this look's whole minute; giving up at once takes next to nothing.
        #expect(await MarkedItemsScan.offPool(finder: held, sources: ["/Users/me"], deadline: 60) == .busy)
        #expect(ContinuousClock.now - started < .seconds(30), "it gives up at once")
        #expect(held.asked.withLock { $0 } == 1)

        held.release.signal()
        // No time bound here: the stuck look returns as soon as it is released, and a wait that never ends is caught
        // by the test run's own limit.
        while held.gate.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
        held.release.signal() // for the next look
        #expect(await MarkedItemsScan.offPool(finder: held, sources: ["/Users/me"], deadline: Self.unreachable) == .found(["/Users/me/a"]))
        #expect(held.asked.withLock { $0 } == 2)
    }

    /// Two plans backing up together: the second look waits for the first, still within its deadline, rather than
    /// giving up or starting a second query at the same time.
    @Test func aLiveLookIsWaitedForThenRunAgain() async {
        let held = Held()
        async let first = MarkedItemsScan.offPool(finder: held, sources: ["/Users/me"], deadline: Self.unreachable)
        while held.asked.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        async let second = MarkedItemsScan.offPool(finder: held, sources: ["/Users/me"], deadline: Self.unreachable)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(held.asked.withLock { $0 } == 1, "never two queries at once")
        held.release.signal()
        held.release.signal()
        #expect(await first == .found(["/Users/me/a"]))
        #expect(await second == .found(["/Users/me/a"]))
        #expect(held.asked.withLock { $0 } == 2)
    }

    @Test func offPoolReturnsTheVerifiedItems() async {
        let index = FakeIndex(.found(["/Users/me/a", "/Users/me/b"]), stillMarked: ["/Users/me/b"])
        #expect(await MarkedItemsScan.offPool(finder: index, sources: ["/Users/me"], deadline: Self.unreachable) == .found(["/Users/me/b"]))
    }

    // MARK: The real attribute check (Spotlight may not index temp folders, so the query itself is faked above)

    @Test func theRealCheckReadsTheAttributeWithoutFollowingSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("restorey-marked-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let marked = root.appendingPathComponent("marked")
        let plain = root.appendingPathComponent("plain")
        let link = root.appendingPathComponent("link")
        try fm.createDirectory(at: marked, withIntermediateDirectories: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: marked)
        // The value `tmutil addexclusion` writes: a binary plist holding the string "com.apple.backupd".
        let value = try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
        let set = value.withUnsafeBytes {
            setxattr(marked.path, MarkedNotForBackup.attributeName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        #expect(set == 0)

        let reader = SpotlightMarkedItems()
        #expect(reader.isMarked(marked.path))
        #expect(!reader.isMarked(plain.path))
        #expect(!reader.isMarked(link.path), "the symlink itself carries no attribute; its target isn’t followed")
        #expect(!reader.isMarked(root.appendingPathComponent("missing").path))
    }

    @Test func theRealQueryAnswersForAFolderSpotlightDoesntIndex() async {
        // A folder Spotlight has no entries for, and one that doesn't exist: no candidates, not a failure.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-unindexed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The query blocks, so it runs on a thread of its own, as the agent's does, not on a Swift concurrency one.
        let reader = SpotlightMarkedItems()
        let found = await OwnThread.run(named: "test Spotlight query", qualityOfService: .utility) {
            [reader.query(scopes: [root.path], limit: 10), reader.query(scopes: [root.path + "-missing"], limit: 10)]
        }
        #expect(found == [.found([]), .found([])])
    }

    // MARK: Stored fields

    @Test func aPlanWithoutTheFieldsSkipsMarkedItemsAndBacksNothingUpAnyway() throws {
        let plan = Plan.newHotPlan(
            name: "P", repository: .raw(repository: "/tmp/r", environmentNames: []), origin: .created,
            hostLabel: "h", sources: [Self.home], exclusions: [], now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(plan.skipsItemsMarkedNotForBackup)
        #expect(plan.backUpAnyway.isEmpty)
        let encoder = VersionedStore<PlanBox>.makeEncoder()
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(plan)) as? [String: Any])
        object["skipsItemsMarkedNotForBackup"] = nil
        object["backUpAnyway"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try VersionedStore<PlanBox>.makeDecoder().decode(Plan.self, from: old)
        #expect(decoded.skipsItemsMarkedNotForBackup)
        #expect(decoded.backUpAnyway.isEmpty)
        #expect(decoded == plan)
    }

    @Test func aPlanRoundTripsTheFields() throws {
        var plan = Plan.newHotPlan(
            name: "P", repository: .raw(repository: "/tmp/r", environmentNames: []), origin: .created,
            hostLabel: "h", sources: [Self.home], exclusions: [], now: Date(timeIntervalSince1970: 1_800_000_000))
        plan.skipsItemsMarkedNotForBackup = false
        plan.backUpAnyway = ["/Users/me/Lightroom"]
        let data = try VersionedStore<PlanBox>.makeEncoder().encode(plan)
        #expect(try VersionedStore<PlanBox>.makeDecoder().decode(Plan.self, from: data) == plan)
    }

    private func record(_ skipped: Int?) -> RunRecord {
        RunRecord(
            id: UUID(), planID: UUID(), operation: .backup, trigger: .scheduled, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060), outcome: .success(snapshotID: "abc"), summary: nil, logFile: "",
            markedNotForBackupSkipped: skipped)
    }

    @Test func aRecordRoundTripsTheCountAndOmitsItWhenNil() throws {
        let original = record(1145)
        #expect(try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(original)) == original)
        let data = try JSONEncoder().encode(record(nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["markedNotForBackupSkipped"] == nil)
        #expect(try JSONDecoder().decode(RunRecord.self, from: data).markedNotForBackupSkipped == nil)
    }

    // MARK: Words

    @Test func theWordsFollowTheCountAndTheSwitch() {
        func line(_ count: Int?, _ skips: Bool = true) -> String {
            MarkedNotForBackupText.line(count: count, skips: skips, locale: Self.en)
        }
        #expect(line(1145) == "Also skipped: 1,145 items apps mark as not for backup")
        #expect(line(1) == "Also skipped: 1 item apps mark as not for backup")
        #expect(line(0) == "Also skipped: items apps mark as not for backup (none found)")
        #expect(line(nil) == "Also skipped: items apps mark as not for backup")
        #expect(line(1145, false) == "Items apps mark as not for backup are included")
        #expect(line(nil, false) == "Items apps mark as not for backup are included")
    }

    /// Review m4 (FDA): without Full Disk Access the app can't read the attribute in protected folders.
    @Test func withoutFullDiskAccessTheListSaysItMayBeIncomplete() {
        #expect(MarkedNotForBackupText.incompleteNote(fullDiskAccessMissing: true)
            == "This list may be incomplete until Restorey has Full Disk Access.")
        #expect(MarkedNotForBackupText.incompleteNote(fullDiskAccessMissing: false) == nil)
    }

    @Test func aPathIsShownWithTheHomeFolderAsATilde() {
        let home = URL(fileURLWithPath: Self.home)
        #expect(MarkedNotForBackupText.displayPath("/Users/me/Library/x", home: home) == "~/Library/x")
        #expect(MarkedNotForBackupText.displayPath("/Users/me", home: home) == "~")
        #expect(MarkedNotForBackupText.displayPath("/Users/meow/x", home: home) == "/Users/meow/x")
    }

    // MARK: The sheet's list

    @Test func theSheetListsEachOuterItemAndWhetherItIsSkipped() {
        let home = URL(fileURLWithPath: Self.home)
        let verified = ["/Users/me/A", "/Users/me/A/inner", "/Users/me/B", "/Users/me/Library/Caches/x"]
        let exclusions = [DefaultExclusions.pattern(forFolder: "/Users/me/Library/Caches")]
        let rows = MarkedItemsList.rows(
            verified: verified, sources: [Self.home], exclusions: exclusions, backUpAnyway: ["/Users/me/B"], home: home)
        #expect(rows == [
            MarkedItemsList.Row(path: "/Users/me/A", display: "~/A", backedUpAnyway: false, coveredByEntryAbove: false),
            MarkedItemsList.Row(path: "/Users/me/B", display: "~/B", backedUpAnyway: true, coveredByEntryAbove: false),
        ])
        #expect(MarkedItemsList.skippedCount(
            verified: verified, sources: [Self.home], exclusions: exclusions, backUpAnyway: ["/Users/me/B"]) == 1)
    }

    @Test func tickingAndUntickingBackUpAnywayEditsTheEntries() {
        #expect(MarkedItemsList.settingBackUpAnyway(true, for: "/Users/me/A", in: ["/Users/me/B"]) == ["/Users/me/B", "/Users/me/A"])
        #expect(MarkedItemsList.settingBackUpAnyway(true, for: "/Users/me/A", in: ["/Users/me/A"]) == ["/Users/me/A"])
        // Unticking removes the entry and any entry inside it; an entry above it stays, because it covers other items
        // too, and so do unrelated entries.
        #expect(MarkedItemsList.settingBackUpAnyway(
            false, for: "/Users/me/A", in: ["/Users/me/A", "/Users/me/A/x", "/Users/me", "/Users/me/B", "/Users/me/AB"])
            == ["/Users/me", "/Users/me/B", "/Users/me/AB"])
    }

    @Test func aRowCoveredByAnEntryAboveItSaysSo() {
        // Only reachable with an entry the sheet didn't make: its checkbox can't untick it, so the sheet disables it.
        let rows = MarkedItemsList.rows(
            verified: ["/Users/me/Work/A", "/Users/me/B"], sources: [Self.home], exclusions: [],
            backUpAnyway: ["/Users/me/Work"], home: URL(fileURLWithPath: Self.home))
        #expect(rows == [
            MarkedItemsList.Row(path: "/Users/me/B", display: "~/B", backedUpAnyway: false, coveredByEntryAbove: false),
            MarkedItemsList.Row(path: "/Users/me/Work/A", display: "~/Work/A", backedUpAnyway: true, coveredByEntryAbove: true),
        ])
    }
}
