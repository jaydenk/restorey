import Foundation
import Testing
@testable import RestoreyCore

/// Task 16b: the files a backup couldn't read, kept on its record (`UnreadableItems.collect`), shown in a sheet
/// (`UnreadableList`), and excluded with "Don't back this up". restic 0.19.1's archival error is
/// `{"message_type":"error","error":{"message":err.Error()},"during":"archival","item":item}`
/// (`internal/ui/backup/json.go`), and the archiver adds the path to an error that lacks it
/// (`internal/archiver/archiver.go`), so the message reads "open /path: operation not permitted".
struct UnreadableItemsTests {
    private static let home = URL(fileURLWithPath: "/Users/me")

    private func archival(_ item: String, _ message: String? = nil) -> ResticItemError {
        ResticItemError(message: message ?? "open \(item): operation not permitted", during: "archival", item: item)
    }

    // MARK: Collecting

    @Test func itemsAreTheDistinctArchivalItemsInOrderWithTheirReasons() {
        let found = UnreadableItems.collect([
            archival("/b"), archival("/a", "lstat /a: no such file or directory"), archival("/b", "read /b: input/output error"),
        ])
        #expect(found == [
            UnreadableItem(path: "/b", reason: "operation not permitted"),
            UnreadableItem(path: "/a", reason: "no such file or directory"),
        ])
    }

    @Test func scanErrorsAndItemlessErrorsAreLeftOut() {
        let scan = ResticItemError(message: "lstat /s: no such file or directory", during: "scan", item: "/s")
        let itemless = ResticItemError(message: "boom", during: "archival", item: nil)
        #expect(UnreadableItems.collect([scan, itemless]) == nil)
        #expect(UnreadableItems.collect([]) == nil)
    }

    @Test func theListStopsAtOneHundred() throws {
        let errors = (0..<130).map { archival("/f\($0)") }
        let found = try #require(UnreadableItems.collect(errors))
        #expect(found.count == 100)
        #expect(found.first?.path == "/f0")
        #expect(found.last?.path == "/f99")
    }

    @Test func theReasonIsWhatFollowsThePathInResticsMessage() {
        func reason(_ message: String, _ item: String = "/a/b") -> String {
            UnreadableItems.shortReason(message: message, item: item)
        }
        #expect(reason("open /a/b: permission denied") == "permission denied")
        #expect(reason("/a/b: operation not permitted") == "operation not permitted")
        #expect(reason("operation not permitted") == "operation not permitted")
        // A path with ": " in it is removed whole, not split.
        #expect(reason("open /a: b/c: no such file or directory", "/a: b/c") == "no such file or directory")
        #expect(reason("open /a/b:") == "")
        #expect(reason(String(repeating: "x", count: 500)).count == UnreadableItems.maxReasonLength)
    }

    // MARK: The record

    private func record(_ items: [UnreadableItem]?) -> RunRecord {
        RunRecord(
            id: UUID(), planID: UUID(), operation: .backup, trigger: .scheduled, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060), outcome: .warning(unreadable: 2), summary: nil, logFile: "",
            unreadableItems: items)
    }

    @Test func aRecordRoundTripsTheItemsAndOmitsThemWhenNil() throws {
        let original = record([UnreadableItem(path: "/a", reason: "operation not permitted")])
        #expect(try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(original)) == original)
        let data = try JSONEncoder().encode(record(nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["unreadableItems"] == nil)
        #expect(try JSONDecoder().decode(RunRecord.self, from: data).unreadableItems == nil)
    }

    @Test func aRecordWrittenBeforeTheFieldExistedDecodesWithNil() throws {
        let json = """
            {"id":"6F1B5C2E-0000-4000-8000-000000000001","planID":"6F1B5C2E-0000-4000-8000-000000000002","operation":{"type":"backup"},
            "trigger":"scheduled","startedAt":"2026-11-12T04:16:00Z","endedAt":"2026-11-12T04:17:00Z",
            "outcome":{"type":"warning","unreadable":3},"logFile":""}
            """
        let decoded = try Self.decoder.decode(RunRecord.self, from: Data(json.utf8))
        #expect(decoded.unreadableItems == nil)
        #expect(decoded.outcome == .warning(unreadable: 3))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Words

    @Test func commonErrnoTextsAreInPlainWords() {
        #expect(UnreadableList.reasonWords("operation not permitted") == "Restorey isn't allowed to read this")
        #expect(UnreadableList.reasonWords("permission denied") == "Restorey isn't allowed to read this")
        #expect(UnreadableList.reasonWords("Permission Denied") == "Restorey isn't allowed to read this")
        #expect(UnreadableList.reasonWords("no such file or directory") == "It was deleted while the backup ran")
        // Anything else is restic's text, starting with a capital.
        #expect(UnreadableList.reasonWords("input/output error") == "Input/output error")
        #expect(UnreadableList.reasonWords("") == "Restic gave no reason")
    }

    @Test func theMoreLineCountsWhatTheCapLeftOut() {
        #expect(UnreadableList.moreLine(count: 130, listed: 100) == "and 30 more")
        #expect(UnreadableList.moreLine(count: 100, listed: 100) == nil)
        #expect(UnreadableList.moreLine(count: 2, listed: 2) == nil)
    }

    // MARK: Rows

    private let permission = UnreadableItem(path: "/Users/me/Library/Caches/Speech", reason: "operation not permitted")
    private let gone = UnreadableItem(path: "/Users/me/tmp/x", reason: "no such file or directory")
    private let io = UnreadableItem(path: "/Users/me/a*b", reason: "input/output error")

    private func rows(
        _ items: [UnreadableItem], exclusions: [String] = [], saved: [String] = [], existing: Set<String> = []
    ) -> [UnreadableList.Row] {
        UnreadableList.rows(
            items: items, exclusions: exclusions, saved: saved, home: Self.home, exists: { existing.contains($0) })
    }

    @Test func aRowShowsTheTildePathReasonAndOffersTheExclusion() throws {
        let row = try #require(rows([permission], existing: [permission.path]).first)
        #expect(row.display == "~/Library/Caches/Speech")
        #expect(row.reason == "Restorey isn't allowed to read this")
        #expect(row.action == .dontBackUp(pattern: DefaultExclusions.pattern(forFolder: permission.path)))
        #expect(row.canOpenInFinder)
    }

    @Test func theExclusionIsTheFolderPatternWithEscaping() throws {
        let row = try #require(rows([io]).first)
        #expect(row.action == .dontBackUp(pattern: #"/Users/me/a\*b"#))
        #expect(!row.canOpenInFinder)
    }

    @Test func aDeletedFileHasNoActionAndNoFinderLink() throws {
        let row = try #require(rows([gone], existing: [gone.path]).first)
        #expect(row.action == .none)
        #expect(!row.canOpenInFinder)
    }

    @Test func anUnsavedExclusionKeepsItsUndoAndASavedOneDoesNot() throws {
        let pattern = DefaultExclusions.pattern(forFolder: permission.path)
        // In the form only: an edit still to save, so Undo is offered (also after the sheet is reopened).
        let unsaved = try #require(rows([permission], exclusions: [pattern], saved: []).first)
        #expect(unsaved.action == .excluded(unsaved: true))
        // In the saved plan too: already so.
        let saved = try #require(rows([permission], exclusions: [pattern], saved: [pattern]).first)
        #expect(saved.action == .excluded(unsaved: false))
        // Removed from the form (Undo, or in the What tab): offered again.
        let removed = try #require(rows([permission], exclusions: [], saved: [pattern]).first)
        #expect(removed.action == .dontBackUp(pattern: pattern))
    }

    // MARK: Editing the plan's exclusions

    @Test func addingAppendsThePatternOnce() {
        let pattern = DefaultExclusions.pattern(forFolder: permission.path)
        let added = UnreadableList.adding(permission.path, to: ["/x"])
        #expect(added == ["/x", pattern])
        #expect(UnreadableList.adding(permission.path, to: added) == added)
    }

    @Test func undoRemovesOnlyThatPattern() {
        let pattern = DefaultExclusions.pattern(forFolder: permission.path)
        #expect(UnreadableList.removing(permission.path, from: ["/x", pattern, "/y"]) == ["/x", "/y"])
        #expect(UnreadableList.removing(permission.path, from: ["/x"]) == ["/x"])
    }

    // MARK: The summary on the Overview and in History

    @Test func theSummaryIsOnlyForAWarningWithItems() throws {
        let items = [permission]
        #expect(UnreadableSummary(record: record(items))?.items == items)
        #expect(UnreadableSummary(record: record(items))?.count == 2)
        #expect(UnreadableSummary(record: record(nil)) == nil)
        #expect(UnreadableSummary(record: record([])) == nil)
        var success = record(items)
        success.outcome = .success(snapshotID: "a")
        #expect(UnreadableSummary(record: success) == nil)
    }
}
