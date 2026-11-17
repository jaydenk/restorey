import Foundation
import Testing
@testable import RestoreyCore

/// Task 16d: each backup's biggest additions. restic 0.19.1 at verbosity 2 (`--verbose`) prints one `verbose_status`
/// line per file and folder (`internal/ui/backup/json.go`, `CompleteItem`), always with every field (no `omitempty`):
/// a new or modified file carries its `data_size_in_repo`, a folder (item ending in "/") only its own tree's size, and
/// an unchanged item zeros. The fixture is modelled on lines captured from the vendored restic. Task 16f adds the
/// folders' own trees (restic's folder listings, `metadata_size_in_repo`).
struct BiggestAdditionsTests {
    private static let home = "/Users/me"

    private func collect(_ fixture: String = "backup-verbose.ndjson", sources: [String] = [home], limit: Int = 50_000)
        throws -> BiggestAdditions?
    {
        let collector = BiggestAdditionsCollector(sources: sources, folderKeyLimit: limit)
        for line in try Fixtures.lines(fixture) {
            // As the drain does: unchanged items never reach the parser.
            if ResticMessageParser.isUnchangedVerboseLine(Array(line.utf8)[...]) { continue }
            collector.collect(ResticMessageParser.parse(line))
        }
        return collector.result()
    }

    private func entry(_ path: String, _ bytes: Int64) -> BiggestAdditions.Entry {
        BiggestAdditions.Entry(path: path, bytesAdded: bytes)
    }

    // MARK: Parsing

    @Test func aVerboseLineIsReadWithItsActionItemAndSizeInTheRepository() {
        let line = #"{"message_type":"verbose_status","action":"new","item":"/src/big.bin","duration":0.002500417,"data_size":300000,"data_size_in_repo":300091,"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#
        #expect(ResticMessageParser.parse(line) == .verboseStatus(VerboseItem(action: "new", item: "/src/big.bin", dataSizeInRepo: 300_091)))
    }

    @Test func escapesInTheItemAreUndone() {
        // Go's encoder escapes `"`, `\`, `&`, `<`, `>` and control characters; a non-ASCII name is written as UTF-8.
        let line = #"{"message_type":"verbose_status","action":"new","item":"/src/q\"&<>\\\t/é😀.txt","duration":0,"data_size":4,"data_size_in_repo":86,"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#
        #expect(ResticMessageParser.parse(line) == .verboseStatus(VerboseItem(
            action: "new", item: "/src/q\"&<>\\\t/é😀.txt", dataSizeInRepo: 86)))
        let pair = #"{"message_type":"verbose_status","action":"new","item":"/a😀","duration":0,"data_size":4,"data_size_in_repo":5,"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#
        #expect(ResticMessageParser.parse(pair) == .verboseStatus(VerboseItem(action: "new", item: "/a😀", dataSizeInRepo: 5)))
    }

    @Test func aFolderLineIsReadWithItsListingSizeInTheRepository() {
        // restic 0.19.1's `dir new`/`dir modified`: the folder's own tree in the metadata fields, its data sizes zero.
        let line = #"{"message_type":"verbose_status","action":"modified","item":"/src/a/","duration":0.3,"data_size":0,"data_size_in_repo":0,"metadata_size":911,"metadata_size_in_repo":462,"total_files":0}"#
        #expect(ResticMessageParser.parse(line) == .verboseStatus(VerboseItem(
            action: "modified", item: "/src/a/", dataSizeInRepo: 0, metadataSizeInRepo: 462)))
        // A line that ends after the data sizes (an older layout) has no listing.
        let short = #"{"message_type":"verbose_status","action":"new","item":"/src/b","duration":0,"data_size":4,"data_size_in_repo":86}"#
        #expect(ResticMessageParser.parse(short) == .verboseStatus(VerboseItem(action: "new", item: "/src/b", dataSizeInRepo: 86)))
        // Read by the decoder too, when the layout is another.
        let other = #"{"message_type":"verbose_status","item":"/src/c/","action":"new","metadata_size_in_repo":50,"data_size_in_repo":0}"#
        #expect(ResticMessageParser.parse(other) == .verboseStatus(VerboseItem(
            action: "new", item: "/src/c/", dataSizeInRepo: 0, metadataSizeInRepo: 50)))
    }

    @Test func aFolderLineCutShortOrBadInItsListingIsNotRead() {
        let start = #"{"message_type":"verbose_status","action":"new","item":"/a/","duration":0,"data_size":0,"data_size_in_repo":0"#
        for line in [
            start + #","metadata_size":911,"metadata_size_in_repo":4"#,          // cut short in the listing's size
            start + #","metadata_size":911,"metadata_size_in_repo":-4}"#,        // negative
            start + #","metadata_size":911,"metadata_size_in_repo":"4"}"#,       // not a number
            start + #","metadata_size":911,"metadata_size_in_repo":99999999999999999999}"#, // too big
            start + #","metadata_size":"#,                                       // cut short
        ] {
            #expect(ResticMessageParser.parse(line) == .verboseStatus(nil), "\(line)")
        }
    }

    @Test func aLineInAnotherOrderIsStillRead() {
        // Not restic 0.19.1's order, so the fast reader declines and the full decoder reads it.
        let line = #"{"message_type":"verbose_status","item":"/a","action":"modified","data_size_in_repo":7}"#
        #expect(ResticMessageParser.parse(line) == .verboseStatus(VerboseItem(action: "modified", item: "/a", dataSizeInRepo: 7)))
        let spaced = #"{"message_type":"verbose_status", "action":"new","item":"/b","data_size_in_repo":9}"#
        #expect(ResticMessageParser.parse(spaced) == .verboseStatus(VerboseItem(action: "new", item: "/b", dataSizeInRepo: 9)))
    }

    @Test func aMalformedOrCutVerboseLineIsAVerboseLineWithNothingToRead() {
        let prefix = #"{"message_type":"verbose_status","action":"new","item":"/a""#
        for line in [
            prefix,                                                               // cut short
            prefix + #","data_size_in_repo":"lots"}"#,                            // not a number
            prefix + #","data_size_in_repo":-5}"#,                                // negative
            #"{"message_type":"verbose_status","action":"new","item":"/a\x"}"#,   // bad escape
            #"{"message_type":"verbose_status","action":"new","item":"/a\ud83d","data_size_in_repo":1}"#, // lone surrogate
        ] {
            #expect(ResticMessageParser.parse(line) == .verboseStatus(nil), "\(line)")
        }
        // A size too big for Int64 isn't trusted either.
        #expect(ResticMessageParser.parse(prefix + #","data_size_in_repo":99999999999999999999}"#) == .verboseStatus(nil))
    }

    @Test func onlyAnUnchangedItemIsDroppedBeforeParsing() {
        func dropped(_ line: String) -> Bool { ResticMessageParser.isUnchangedVerboseLine(Array(line.utf8)[...]) }
        #expect(dropped(#"{"message_type":"verbose_status","action":"unchanged","item":"/a","duration":0,"data_size":0,"data_size_in_repo":0,"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#))
        #expect(!dropped(#"{"message_type":"verbose_status","action":"new","item":"/unchanged"}"#))
        #expect(!dropped(#"{"message_type":"verbose_status","action":"unchangedish","item":"/a"}"#))
        #expect(!dropped(#"{"message_type":"status","action":"unchanged"}"#))
        #expect(!dropped(#"{"message_type":"verbose_status","action":"unchan"#))
        #expect(!dropped(""))
        // A new or modified folder carries its listing's size: never dropped.
        #expect(!dropped(#"{"message_type":"verbose_status","action":"modified","item":"/a/","duration":0,"data_size":0,"data_size_in_repo":0,"metadata_size":9,"metadata_size_in_repo":5,"total_files":0}"#))
        #expect(!dropped(#"{"message_type":"verbose_status","action":"new","item":"/a/","duration":0,"data_size":0,"data_size_in_repo":0,"metadata_size":9,"metadata_size_in_repo":5,"total_files":0}"#))
        // The prefix is matched anywhere in a slice, not only at index 0 of its base array.
        let bytes = Array(("xx" + #"{"message_type":"verbose_status","action":"unchanged","item":"/a"}"#).utf8)
        #expect(ResticMessageParser.isUnchangedVerboseLine(bytes[2...]))
    }

    // MARK: Collecting

    @Test func theTopTenFilesAreTheBiggestInTheRepositoryWithTiesByPath() throws {
        let additions = try #require(try collect())
        #expect(additions.files == [
            entry("/Users/me/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", 1_100_000_123),
            entry("/Users/me/Library/Logs/big.log", 20_000_000),
            entry("/Users/me/Library/Application Support/BeeperTexts/index.db", 300_000),
            entry("/Users/me/Library/Application Support/BeeperTexts/blob/1", 200_000),
            entry("/Users/me/Library/Application Support/BeeperTexts/blob/2", 200_000),
            entry("/Users/me/Documents/c.pages", 8_000),
            entry("/Users/me/Documents/d.pages", 7_000),
            entry("/Users/me/Documents/e.pages", 6_000),
            entry("/Users/me/Documents/f.pages", 5_000),
            // b.jpg (also 4,000) arrived first, but a.jpg sorts first.
            entry("/Users/me/Pictures/a.jpg", 4_000),
        ])
        // Every file's size in the repository, the zero-size and unchanged ones adding nothing; folders' own trees are
        // counted apart, as listings (Task 16f).
        #expect(additions.totalBytesAdded == 1_120_737_213)
        #expect(!additions.foldersIncomplete)
    }

    @Test func folderListingsAreEveryNewOrModifiedFoldersTreeInTheRepository() throws {
        let additions = try #require(try collect())
        // database/ 120,000 + BeeperTexts/blob/ 400 + Pictures/ 462 + the source 466 + /Users/ (above the source) 250;
        // the unchanged Music/ carries nothing.
        #expect(additions.listingsBytesAdded == 121_578)
        // With the root's own tree (never printed: restic reports it with no node), restic's data_added_packed.
        #expect(additions.totalBytesAdded + additions.listingsBytesAdded! <= 1_120_859_091)
    }

    @Test func theTopFiveFoldersSumTheirFilesAndListingsUpToThreeFoldersDownOrAtAPackage() throws {
        let additions = try #require(try collect())
        #expect(additions.folders == [
            // Photos.sqlite and the database/ folder's listing.
            entry("/Users/me/Pictures/Photos Library.photoslibrary", 1_100_120_123),
            entry("/Users/me/Library/Logs", 20_000_000),
            // Its blob/ subfolder is a fourth level down, so its files and listing count here.
            entry("/Users/me/Library/Application Support/BeeperTexts", 700_400),
            entry("/Users/me/Documents", 26_000),
            // a.jpg, b.jpg and Pictures/'s own listing.
            entry("/Users/me/Pictures", 8_462),
        ])
    }

    @Test func aFoldersListingCountsTowardsItselfAndAboveTheSourcesTowardsNoFolder() {
        let key = { (path: String, sources: [String]) in BiggestAdditionsCollector.folderKey(forFolder: path, roots: sources) }
        #expect(key("/Users/me/", ["/Users/me"]) == "/Users/me")
        #expect(key("/Users/me/Documents/", ["/Users/me"]) == "/Users/me/Documents")
        #expect(key("/Users/me/a/b/c/d/", ["/Users/me"]) == "/Users/me/a/b/c")
        #expect(key("/Users/me/a/Lib.photoslibrary/x/", ["/Users/me"]) == "/Users/me/a/Lib.photoslibrary")
        #expect(key("/Users/me/a/Lib.photoslibrary/", ["/Users/me"]) == "/Users/me/a/Lib.photoslibrary")
        // The folders restic records on the way down to a source aren't part of any.
        #expect(key("/Users/", ["/Users/me"]) == nil)
        #expect(key("/Users/", ["/Users/me", "/Volumes/X"]) == nil)
        // A source of "/" holds them all.
        #expect(key("/Users/", ["/"]) == "/Users")
        #expect(key("/Users/me/Pictures/P.photoslibrary/database/", ["/"]) == "/Users/me/Pictures")
        // The deepest source holding the folder wins, and a source is its own folder.
        #expect(key("/Users/me/Pictures/", ["/Users/me", "/Users/me/Pictures"]) == "/Users/me/Pictures")
        #expect(key("/Users/meadow/", ["/Users/me"]) == nil)
    }

    @Test func folderKeys() {
        let key = { (path: String, sources: [String]) in BiggestAdditionsCollector.folderKey(path, roots: sources) }
        #expect(key("/Users/me/notes.txt", ["/Users/me"]) == "/Users/me")
        #expect(key("/Users/me/a/b/c/d/e.txt", ["/Users/me"]) == "/Users/me/a/b/c")
        #expect(key("/Users/me/a/Lib.photoslibrary/x/y.db", ["/Users/me"]) == "/Users/me/a/Lib.photoslibrary")
        // A hidden folder isn't a package.
        #expect(key("/Users/me/.cache/pip/http/x", ["/Users/me"]) == "/Users/me/.cache/pip/http")
        // A source of "/" counts from the top.
        #expect(key("/Users/me/Pictures/Photos Library.photoslibrary/database/Photos.sqlite", ["/"]) == "/Users/me/Pictures")
        #expect(key("/etc.txt", ["/"]) == "/")
        // The deepest source holding the file wins.
        #expect(key("/Users/me/Pictures/Lib.photoslibrary/db/x", ["/Users/me", "/Users/me/Pictures"])
            == "/Users/me/Pictures/Lib.photoslibrary")
        // A source that is a file: its folder.
        #expect(key("/Users/me/big.iso", ["/Users/me/big.iso"]) == "/Users/me")
        // A file under no source (restic can't report one, but never trap): counted from "/".
        #expect(key("/Volumes/X/a/b/c/d", ["/Users/me"]) == "/Volumes/X/a")
        // "/Users/meadow" is not inside "/Users/me".
        #expect(key("/Users/meadow/a/b", ["/Users/me"]) == "/Users/meadow/a")
    }

    @Test func aSourceOfTheRootGroupsUnderTheTopFolders() throws {
        let additions = try #require(try collect(sources: ["/"]))
        #expect(additions.folders.map(\.path) == [
            "/Users/me/Pictures", "/Users/me/Library", "/Users/me/Documents", "/Users/me/Music", "/Users/me",
        ])
        // Its files, Pictures/'s listing and the database/ folder's.
        #expect(additions.folders.first?.bytesAdded == 1_100_128_585)
        #expect(additions.listingsBytesAdded == 121_578)
    }

    @Test func newFolderKeysStopAtTheLimitAndTheRecordSaysSo() throws {
        let additions = try #require(try collect(limit: 2))
        // The first two folders seen keep counting, their listings too; later ones are left out.
        #expect(additions.folders == [
            entry("/Users/me/Pictures/Photos Library.photoslibrary", 1_100_120_123),
            entry("/Users/me/Library/Application Support/BeeperTexts", 700_400),
        ])
        #expect(additions.foldersIncomplete)
        // Files and the totals are unaffected.
        #expect(additions.files.count == 10)
        #expect(additions.totalBytesAdded == 1_120_737_213)
        #expect(additions.listingsBytesAdded == 121_578)
    }

    @Test func noVerboseLineMeansNothingToReport() {
        let collector = BiggestAdditionsCollector(sources: ["/"])
        collector.collect(.status(BackupStatus()))
        collector.collect(.summary(BackupSummary(snapshotID: "a")))
        #expect(collector.result() == nil)
    }

    @Test func verboseLinesWithNoDataAddedReportEmptyLists() {
        let collector = BiggestAdditionsCollector(sources: ["/"])
        collector.collect(.verboseStatus(VerboseItem(action: "scan_finished", item: "", dataSizeInRepo: 0)))
        collector.collect(.verboseStatus(VerboseItem(action: "modified", item: "/a/", dataSizeInRepo: 0)))
        collector.collect(.verboseStatus(VerboseItem(action: "new", item: "/a/empty", dataSizeInRepo: 0)))
        // An unchanged folder never carries a size; were one to, it isn't counted.
        collector.collect(.verboseStatus(VerboseItem(action: "unchanged", item: "/a/b/", dataSizeInRepo: 0, metadataSizeInRepo: 9)))
        collector.collect(.verboseStatus(nil))
        #expect(collector.result() == BiggestAdditions(files: [], folders: [], totalBytesAdded: 0, listingsBytesAdded: 0))
    }

    @Test func listingsAloneAreCountedWithNoFileAdded() {
        let collector = BiggestAdditionsCollector(sources: ["/s"])
        collector.collect(.verboseStatus(VerboseItem(action: "modified", item: "/s/a/", dataSizeInRepo: 0, metadataSizeInRepo: 300)))
        collector.collect(.verboseStatus(VerboseItem(action: "modified", item: "/s/", dataSizeInRepo: 0, metadataSizeInRepo: 200)))
        collector.collect(.verboseStatus(VerboseItem(action: "modified", item: "/", dataSizeInRepo: 0, metadataSizeInRepo: 100)))
        #expect(collector.result() == BiggestAdditions(
            files: [], folders: [entry("/s/a", 300), entry("/s", 200)], totalBytesAdded: 0, listingsBytesAdded: 600))
    }

    @Test func theTopTenDoesntDependOnArrivalOrder() throws {
        let items = (0..<40).map { VerboseItem(action: "new", item: "/s/f\($0)", dataSizeInRepo: Int64($0 % 7) * 100 + 1) }
        func run(_ order: [VerboseItem]) -> BiggestAdditions? {
            let collector = BiggestAdditionsCollector(sources: ["/s"])
            for item in order { collector.collect(.verboseStatus(item)) }
            return collector.result()
        }
        var generator = SystemRandomNumberGenerator()
        #expect(run(items) == run(items.reversed()))
        #expect(run(items) == run(items.shuffled(using: &generator)))
        #expect(run(items)?.files.count == 10)
    }

    // MARK: The record

    private func record(_ additions: BiggestAdditions?) -> RunRecord {
        RunRecord(
            id: UUID(), planID: UUID(), operation: .backup, trigger: .scheduled, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060), outcome: .success(snapshotID: "a"), summary: nil, logFile: "",
            biggestAdditions: additions)
    }

    @Test func aRecordRoundTripsTheAdditionsAndOmitsThemWhenNil() throws {
        let original = record(BiggestAdditions(
            files: [entry("/a/b", 5)], folders: [entry("/a", 5)], totalBytesAdded: 5, listingsBytesAdded: 7,
            foldersIncomplete: true))
        #expect(try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(original)) == original)
        let data = try JSONEncoder().encode(record(nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["biggestAdditions"] == nil)
        #expect(try JSONDecoder().decode(RunRecord.self, from: data).biggestAdditions == nil)
    }

    @Test func theAdditionsJSONIsSmallAndExplicit() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(BiggestAdditions(
            files: [entry("/a/b", 5)], folders: [entry("/a", 5)], totalBytesAdded: 5)), as: UTF8.self)
        // foldersIncomplete is left out while false, listingsBytesAdded while nil.
        #expect(text == #"{"files":[{"bytesAdded":5,"path":"\/a\/b"}],"folders":[{"bytesAdded":5,"path":"\/a"}],"totalBytesAdded":5}"#)
        let withListings = String(decoding: try encoder.encode(BiggestAdditions(
            files: [], folders: [], totalBytesAdded: 0, listingsBytesAdded: 0)), as: UTF8.self)
        #expect(withListings == #"{"files":[],"folders":[],"listingsBytesAdded":0,"totalBytesAdded":0}"#)
        // A record written before Task 16f has none.
        let old = #"{"files":[{"path":"/a/b","bytesAdded":5}],"folders":[],"totalBytesAdded":5}"#
        #expect(try JSONDecoder().decode(BiggestAdditions.self, from: Data(old.utf8)).listingsBytesAdded == nil)
        // Lists a newer build wrote longer are kept to this build's caps.
        let long = #"{"files":[\#((0..<12).map { #"{"path":"/f\#($0)","bytesAdded":1}"# }.joined(separator: ","))],"folders":[],"totalBytesAdded":12}"#
        let decoded = try JSONDecoder().decode(BiggestAdditions.self, from: Data(long.utf8))
        #expect(decoded.files.count == 10)
    }

    @Test func aRecordWrittenBeforeTheFieldExistedDecodesWithNil() throws {
        let json = """
            {"id":"6F1B5C2E-0000-4000-8000-000000000001","planID":"6F1B5C2E-0000-4000-8000-000000000002","operation":{"type":"backup"},
            "trigger":"scheduled","startedAt":"2026-11-12T04:16:00Z","endedAt":"2026-11-12T04:17:00Z",
            "outcome":{"type":"success","snapshotID":"abc"},"logFile":""}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(RunRecord.self, from: Data(json.utf8)).biggestAdditions == nil)
    }

    // MARK: The run log

    @Test func theRunLogLineNamesTheFilesAndFolders() throws {
        let additions = BiggestAdditions(
            files: [entry("/Users/me/Pictures/P.photoslibrary/database/Photos.sqlite", 1_100_000_000), entry("/Users/me/a.log", 1_500)],
            folders: [entry("/Users/me/Pictures/P.photoslibrary", 1_100_000_000)], totalBytesAdded: 1_100_001_500)
        #expect(BiggestAdditionsText.logLine(additions) ==
            "Biggest additions (files added 1.1 GB to the repository): /Users/me/Pictures/P.photoslibrary/database/Photos.sqlite "
            + "1.1 GB, /Users/me/a.log 1.5 kB; by folder: /Users/me/Pictures/P.photoslibrary 1.1 GB")
        #expect(BiggestAdditionsText.logLine(BiggestAdditions(files: [], folders: [], totalBytesAdded: 0))
            == "Biggest additions: no file added data")
        #expect(BiggestAdditionsText.logLine(nil) == "Biggest additions: restic didn't report them")
        var capped = additions
        capped.foldersIncomplete = true
        #expect(BiggestAdditionsText.logLine(capped).hasSuffix(" (too many folders to count them all)"))
    }

    @Test func theRunLogLineSaysWhatTheFolderListingsAdded() {
        let additions = BiggestAdditions(
            files: [entry("/Users/me/a.log", 1_240_000_000)], folders: [entry("/Users/me", 2_530_000_000)],
            totalBytesAdded: 1_240_000_000, listingsBytesAdded: 1_290_000_000)
        #expect(BiggestAdditionsText.logLine(additions) ==
            "Biggest additions (files added 1.2 GB, folder listings 1.3 GB to the repository): /Users/me/a.log 1.2 GB; "
            + "by folder: /Users/me 2.5 GB")
        #expect(BiggestAdditionsText.logLine(BiggestAdditions(files: [], folders: [], totalBytesAdded: 0, listingsBytesAdded: 4_000))
            == "Biggest additions: no file added data (folder listings 4 kB to the repository)")
        #expect(BiggestAdditionsText.logLine(BiggestAdditions(files: [], folders: [], totalBytesAdded: 0, listingsBytesAdded: 0))
            == "Biggest additions: no file added data")
    }

    @Test func aShortfallAgainstResticsTotalOfMoreThanTenPercentIsLogged() {
        let additions = BiggestAdditions(
            files: [entry("/s/a", 1_000_000)], folders: [], totalBytesAdded: 1_000_000, listingsBytesAdded: 100_000)
        // 1.1 MB counted: within 10% of 1.2 MB, nothing said.
        #expect(BiggestAdditionsText.shortfallLogLine(additions, dataAddedPacked: 1_200_000) == nil)
        #expect(BiggestAdditionsText.shortfallLogLine(additions, dataAddedPacked: 1_100_000) == nil)
        // 1.1 MB of 2.5 MB: said, with all three numbers.
        #expect(BiggestAdditionsText.shortfallLogLine(additions, dataAddedPacked: 2_500_000) ==
            "Biggest additions: files (1 MB) and folder listings (100 kB) come to 1.1 MB, 1.4 MB less than the 2.5 MB "
            + "restic says the backup added to the repository (data_added_packed)")
        // Nothing to compare with: no listings recorded (an older record), no total, or no additions.
        var old = additions
        old.listingsBytesAdded = nil
        #expect(BiggestAdditionsText.shortfallLogLine(old, dataAddedPacked: 2_500_000) == nil)
        #expect(BiggestAdditionsText.shortfallLogLine(additions, dataAddedPacked: nil) == nil)
        #expect(BiggestAdditionsText.shortfallLogLine(nil, dataAddedPacked: 2_500_000) == nil)
    }
}
