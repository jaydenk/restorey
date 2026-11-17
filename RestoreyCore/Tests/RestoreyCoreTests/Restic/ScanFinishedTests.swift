import Foundation
import Testing
@testable import RestoreyCore

/// Task 16e: restic counts the files and bytes to back up while it is already backing them up, so its totals grow for
/// as long as the scan runs. At verbosity 2 it says when the scan ends (`verbose_status`, `action: scan_finished`,
/// `internal/ui/backup/json.go` `ReportTotal`, restic 0.19.1); until then the app doesn't show a percentage.
struct ScanFinishedTests {
    /// The exact line captured from restic 0.19.1 (Fixtures/backup-verbose.ndjson).
    private static let line = #"{"message_type":"verbose_status","action":"scan_finished","item":"","duration":0.001852375,"data_size":9000000,"data_size_in_repo":0,"metadata_size":0,"metadata_size_in_repo":0,"total_files":16}"#

    @Test func theScanFinishedLineIsRecognised() throws {
        guard case .verboseStatus(let item?) = ResticMessageParser.parse(Self.line) else {
            Issue.record("not a verbose item")
            return
        }
        #expect(item.isScanFinished)
        #expect(!item.isAddedFile)
    }

    @Test func otherLinesAreNotTheScanFinishing() {
        for action in ["new", "modified", "unchanged", "scan_finished_not"] {
            let item = VerboseItem(action: action, item: "/a", dataSizeInRepo: 5)
            #expect(!item.isScanFinished, "\(action)")
        }
        // The decoder's reading of a line in another layout (spaces after the colons) counts the same.
        let spaced = #"{"message_type": "verbose_status", "action": "scan_finished", "item": "", "duration": 0.1, "data_size": 9, "data_size_in_repo": 0, "total_files": 1}"#
        guard case .verboseStatus(let item?) = ResticMessageParser.parse(spaced) else {
            Issue.record("not a verbose item")
            return
        }
        #expect(item.isScanFinished)
    }

    @Test func theUnchangedFastPathDoesntSwallowIt() {
        #expect(!ResticMessageParser.isUnchangedVerboseLine(Array(Self.line.utf8)[...]))
    }

    @Test func theBiggestAdditionsIgnoreIt() {
        let collector = BiggestAdditionsCollector(sources: ["/s"])
        collector.collect(ResticMessageParser.parse(Self.line))
        collector.collect(.verboseStatus(VerboseItem(action: "new", item: "/s/a", dataSizeInRepo: 40)))
        #expect(collector.result() == BiggestAdditions(
            files: [.init(path: "/s/a", bytesAdded: 40)], folders: [.init(path: "/s", bytesAdded: 40)], totalBytesAdded: 40))
    }

    @Test func aStatusKeepsItsOwnFlagThroughTheAgentsWireFormat() throws {
        let status = BackupStatus(percentDone: 0.5, totalBytes: 10, bytesDone: 5, scanFinished: true)
        let decoded = try JSONDecoder().decode(BackupStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
        // A status from an agent that predates the flag has none: the scan is not known to be over.
        let old = #"{"percentDone":0.5,"totalFiles":2,"filesDone":1,"totalBytes":10,"bytesDone":5,"errorCount":0,"currentFiles":[]}"#
        #expect(try JSONDecoder().decode(BackupStatus.self, from: Data(old.utf8)).scanFinished == false)
    }

    /// Under the vendored restic: a small backup of a temporary tree into a temporary repository reports the scan as
    /// finished, before its summary, and the line is the one the reader expects.
    @Test(.timeLimit(.minutes(1))) func realResticReportsTheScanFinishingBeforeTheSummary() async throws {
        let repo = try TempRepository()
        defer { repo.remove() }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try name.write(to: repo.source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await repo.initialise()
        let run = try await repo.run(.backup)
        #expect(run.termination.exitCode == 0, "\(run.termination.stderrTail)")
        let finished = run.messages.indices.filter {
            if case .verboseStatus(let item?) = run.messages[$0] { item.isScanFinished } else { false }
        }
        #expect(finished.count == 1)
        let summary = run.messages.firstIndex { if case .summary = $0 { true } else { false } }
        #expect(try #require(finished.first) < #require(summary))
    }
}
