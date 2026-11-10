import Foundation
import Testing
@testable import RestoreyCore

struct ResticMessageTests {
    private func messages(_ fixture: String) throws -> [ResticMessage] {
        try Fixtures.lines(fixture).map(ResticMessageParser.parse)
    }

    @Test func parsesStatusFromFixture() throws {
        let all = try messages("backup-progress.ndjson")
        let statuses = all.compactMap { message -> BackupStatus? in
            if case .status(let s) = message { return s }
            return nil
        }
        #expect(statuses.count >= 3)
        let last = try #require(statuses.last)
        // Real restic never prints a final status at 1.0: the summary is the completion signal.
        #expect(last.percentDone > 0.9 && last.percentDone <= 1)
        #expect(last.totalFiles == 30)
        #expect(last.filesDone == 28)
        #expect(last.totalBytes == 1_200_000_000)
        #expect(last.bytesDone == 1_185_276_558)
        #expect(last.currentFiles == ["/fixture/src/f8.bin", "/fixture/src/f9.bin"])
        #expect(last.errorCount == 0)
        // seconds_remaining is absent from the last status.
        #expect(last.secondsRemaining == nil)
        #expect(statuses.first?.secondsRemaining == 1)
    }

    @Test func parsesSummaryWithSnapshotID() throws {
        let all = try messages("backup-progress.ndjson")
        guard case .summary(let s)? = all.last else {
            Issue.record("last line is not a summary: \(String(describing: all.last))")
            return
        }
        #expect(s.snapshotID == "c6a2e5efd5c15e162dabcb31c2ca53d3a2315d1e5a024ff87e9f0d726b1a1fe6")
        #expect(s.filesNew == 30)
        #expect(s.filesChanged == 0)
        #expect(s.filesUnmodified == 0)
        #expect(s.dataAdded == 1_200_068_348)
        #expect(s.dataAddedPacked == 1_200_128_251)
        #expect(s.totalFilesProcessed == 30)
        #expect(s.totalBytesProcessed == 1_200_000_000)
        #expect(abs(s.totalDuration - 3.350771417) < 1e-9)
        // "2026-11-10T18:33:42.939137+10:30" is 08:03:42.939137 UTC.
        let start = try #require(s.backupStart)
        #expect(abs(start.timeIntervalSince1970 - utc(2026, 11, 10, 8, 3, 42.939137)) < 1e-3)
        let end = try #require(s.backupEnd)
        #expect(abs(end.timeIntervalSince1970 - utc(2026, 11, 10, 8, 3, 46.289919)) < 1e-3)
    }

    @Test func unchangedSummaryHasNilSnapshotID() throws {
        let all = try messages("backup-unchanged.ndjson")
        #expect(all.count == 1)
        guard case .summary(let s)? = all.first else {
            Issue.record("not a summary: \(all)")
            return
        }
        #expect(s.snapshotID == nil)
        #expect(s.filesUnmodified == 1)
        #expect(s.dataAdded == 0)
    }

    @Test func parsesStderrItemError() throws {
        let all = try messages("backup-unreadable.stderr.ndjson")
        guard case .error(let e) = all[0] else {
            Issue.record("first line is not an error: \(all)")
            return
        }
        #expect(e.message == "open /fixture/src/secret.txt: permission denied")
        #expect(e.during == "archival")
        #expect(e.item == "/fixture/src/secret.txt")
        #expect(all[1] == .exitError(code: 3, message: "Warning: at least one source file could not be read"))
    }

    @Test func unreadableBackupStillHasASummaryOnStdout() throws {
        let all = try messages("backup-unreadable.stdout.ndjson")
        guard case .summary(let s)? = all.last else {
            Issue.record("no summary: \(all)")
            return
        }
        #expect(s.snapshotID != nil)
    }

    @Test func parsesExitError() throws {
        let all = try messages("wrong-password.stderr.ndjson")
        #expect(all == [.exitError(code: 12, message: "Fatal: wrong password or no key found")])
    }

    @Test func parsesCredentialHelperFailure() throws {
        let all = try messages("credentials-missing.stderr.ndjson")
        guard case .exitError(let code, let message)? = all.first else {
            Issue.record("not an exit_error: \(all)")
            return
        }
        #expect(code == 1)
        #expect(message.contains("s3.getCredentials: no credentials found"))
        #expect(message.contains("s3.example.invalid"))
    }

    @Test func checkSummaryIsToldApartFromBackupSummary() throws {
        let ok = try messages("check.ndjson")
        #expect(ok == [.checkSummary(CheckSummary(
            numErrors: 0, brokenPacks: nil, suggestRepairIndex: false, suggestPrune: false))])

        let bad = try messages("check-failed.ndjson")
        #expect(bad == [.checkSummary(CheckSummary(
            numErrors: 1,
            brokenPacks: ["615113e8c43a24b98a5a716f9cf247d325fe4548956f3a1344739746778a64d5"],
            suggestRepairIndex: false, suggestPrune: false))])

        // Neither shape is mistaken for the other, whichever fields are missing.
        if case .summary = ResticMessageParser.parse(#"{"message_type":"summary","files_new":1}"#) {} else {
            Issue.record("a backup summary was not parsed as one")
        }
        if case .checkSummary = ResticMessageParser.parse(#"{"message_type":"summary","num_errors":2}"#) {} else {
            Issue.record("a check summary was not parsed as one")
        }
    }

    @Test func checkErrorsUseAFlatMessageField() throws {
        // `check --json` writes {"message_type":"error","message":"..."}, unlike backup's nested error.
        let all = try messages("check-failed.stderr.ndjson")
        #expect(all.count == 5)
        guard case .error(let e) = all[0] else {
            Issue.record("not an error: \(all[0])")
            return
        }
        #expect(e.message.hasPrefix("pack 615113e8"))
        #expect(e.during == nil)
        #expect(e.item == nil)
        #expect(all.last == .exitError(code: 1, message: "Fatal: repository contains errors"))
    }

    @Test func unknownTypeIsKept() {
        #expect(ResticMessageParser.parse(#"{"message_type":"from_the_future","x":1}"#)
            == .unknown(type: "from_the_future"))
    }

    @Test func initialisedIsKeptAsUnknown() throws {
        // `init --json` prints one of these; the parser has no use for it but must not fail.
        #expect(ResticMessageParser.parse(#"{"message_type":"initialized","id":"abc","repository":"/fixture/repo"}"#)
            == .unknown(type: "initialized"))
    }

    @Test func verboseStatusIsRecognised() {
        #expect(ResticMessageParser.parse(#"{"message_type":"verbose_status","action":"new","item":"/fixture/a","duration":0.1,"data_size":5,"metadata_size":0,"total_files":1}"#)
            == .verboseStatus)
    }

    @Test func unknownFieldsAreIgnored() {
        let line = #"{"message_type":"exit_error","code":10,"message":"Fatal: repository does not exist","extra":{"a":[1,2]},"more":null}"#
        #expect(ResticMessageParser.parse(line) == .exitError(code: 10, message: "Fatal: repository does not exist"))
        let status = #"{"message_type":"status","percent_done":0.5,"total_files":2,"files_done":1,"total_bytes":10,"bytes_done":5,"future":true}"#
        guard case .status(let s) = ResticMessageParser.parse(status) else {
            Issue.record("status with an extra field was not parsed")
            return
        }
        #expect(s.percentDone == 0.5)
        #expect(s.currentFiles.isEmpty)
    }

    @Test func malformedAndTruncatedLinesAreUnparseable() {
        let lines = [
            #"{"message_type":"status","percent_do"#,
            "",
            "   ",
            "not json at all",
            "[1,2,3]",
            "null",
            #"{"no_message_type":true}"#,
            #"{"message_type":42}"#,
            #"{"message_type":"exit_error","code":"twelve","message":"x"}"#,
            #"{"message_type":"exit_error","code":12}"#,
            #"{"message_type":"error"}"#,
            #"{"message_type":"summary","files_new":"many"}"#,
            "{\"message_type\":\"status\",\"percent_done\":\u{0}",
        ]
        for line in lines {
            #expect(ResticMessageParser.parse(line) == .unparseable(line), "\(line)")
        }
    }

    @Test func aTrailingCarriageReturnIsTolerated() {
        #expect(ResticMessageParser.parse("{\"message_type\":\"exit_error\",\"code\":11,\"message\":\"m\"}\r")
            == .exitError(code: 11, message: "m"))
    }

    @Test func summaryDatesAcceptZAndOffsets() throws {
        let z = ResticMessageParser.parse(#"{"message_type":"summary","backup_start":"2027-01-15T08:00:00.5Z","backup_end":"2027-01-15T08:00:01Z","snapshot_id":"x"}"#)
        guard case .summary(let s) = z else {
            Issue.record("not a summary: \(z)")
            return
        }
        #expect(s.backupStart == Date(timeIntervalSince1970: utc(2027, 1, 15, 8, 0, 0.5)))
        #expect(s.backupEnd == Date(timeIntervalSince1970: utc(2027, 1, 15, 8, 0, 1)))
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        return base.timeIntervalSince1970 + s
    }
}
