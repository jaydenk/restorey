import Foundation
import Testing
@testable import RestoreyCore

struct RunOutcomeTests {
    private func summary(snapshotID: String?) -> BackupSummary {
        BackupSummary(snapshotID: snapshotID)
    }

    private func item(_ name: String) -> ResticItemError {
        ResticItemError(message: "open \(name): permission denied", during: "archival", item: name)
    }

    private func outcome(
        _ code: Int32,
        op: ResticOperation = .backup,
        intent: InterruptIntent? = nil,
        summary: BackupSummary? = nil,
        errors: [ResticItemError] = [],
        message: String? = nil,
        signal: Int32? = nil,
        killedByUs: Bool = false
    ) -> RunOutcome {
        classify(
            operation: op, exitCode: code, interruptedByUs: intent, terminatedBySignal: signal, killedByUs: killedByUs,
            summary: summary, errors: errors, exitErrorMessage: message)
    }

    @Test func exitZeroWithASnapshotIsSuccess() {
        #expect(outcome(0, summary: summary(snapshotID: "abc")) == .success(snapshotID: "abc"))
    }

    @Test func exitZeroWithoutASnapshotIsUnchanged() {
        #expect(outcome(0, summary: summary(snapshotID: nil)) == .unchanged)
    }

    @Test func backupExitZeroWithoutASummaryFails() {
        #expect(outcome(0, summary: nil)
            == .failed(exitCode: 0, reason: "restic finished without reporting a backup summary"))
    }

    @Test(arguments: [
        ResticOperation.initRepository, .forget(dryRun: false), .forget(dryRun: true), .prune, .check,
        .snapshots(allHosts: false), .snapshots(allHosts: true), .unlock, .catConfig,
    ])
    func nonBackupExitZeroIsSuccess(op: ResticOperation) {
        #expect(outcome(0, op: op) == .success(snapshotID: nil))
    }

    @Test func exitThreeIsAWarningCountingUnreadableItems() {
        #expect(outcome(3, summary: summary(snapshotID: "abc"), errors: [item("/a"), item("/b")])
            == .warning(unreadable: 2))
    }

    @Test func repositoryExitCodesMapToTheirCases() {
        #expect(outcome(10, message: "Fatal: repository does not exist") == .repositoryMissing)
        #expect(outcome(11, message: "Fatal: unable to create lock") == .locked)
        #expect(outcome(12, message: "Fatal: wrong password or no key found") == .wrongPassword)
    }

    @Test func exit130FollowsOurInterruptIntent() {
        #expect(outcome(130, intent: .pause) == .paused)
        #expect(outcome(130, intent: .cancel) == .cancelled)
        guard case .failed(let code, _) = outcome(130, intent: nil) else {
            Issue.record("an interrupt we did not ask for must be a failure")
            return
        }
        #expect(code == 130)
    }

    /// Rulings R12 and R15: restic ignored our SIGINT and `ResticProcess` sent SIGKILL (exit 128 + 9).
    @Test func aProcessWeInterruptedThenKilledStillPausesOrCancels() {
        #expect(outcome(137, intent: .pause, signal: SIGKILL, killedByUs: true) == .paused)
        #expect(outcome(137, intent: .cancel, signal: SIGKILL, killedByUs: true) == .cancelled)
        #expect(outcome(130, intent: .pause, signal: SIGINT) == .paused)
    }

    @Test func otherSignalDeathsAreFailuresEvenAfterOurInterrupt() {
        for (code, signal, ours) in [(Int32(134), SIGABRT, false), (139, SIGSEGV, false), (137, SIGKILL, false)] {
            guard case .failed(let reported, _) = outcome(code, intent: .pause, signal: signal, killedByUs: ours) else {
                Issue.record("signal \(signal) after our interrupt must be a failure")
                continue
            }
            #expect(reported == code)
        }
        // We never send SIGABRT, so the flag cannot excuse it.
        if case .failed = outcome(134, intent: .pause, signal: SIGABRT, killedByUs: true) {} else {
            Issue.record("only our SIGKILL is excused")
        }
    }

    @Test func aSignalDeathWeDidNotAskForIsAFailure() {
        guard case .failed(let code, _) = outcome(137, intent: nil, signal: SIGKILL) else {
            Issue.record("a process killed by a signal we did not send must be a failure")
            return
        }
        #expect(code == 137)
    }

    @Test func ourInterruptDoesNotHideAFinishedOrFailedRun() {
        // The signal arrived after restic had already finished, or restic failed for its own reason.
        #expect(outcome(0, intent: .cancel, summary: summary(snapshotID: "abc")) == .success(snapshotID: "abc"))
        #expect(outcome(12, intent: .pause) == .wrongPassword)
        if case .failed = outcome(1, intent: .cancel) {} else { Issue.record("exit 1 after cancel is a failure") }
    }

    @Test func missingCredentialsAreRecognisedOnExitOne() {
        let message = "Fatal: unable to open repository at s3:https://s3.example.invalid/b/p: s3.getCredentials: no credentials found. Use `-o s3.unsafe-anonymous-auth=true` for anonymous authentication"
        #expect(outcome(1, message: message) == .credentialsUnavailable)
        // Only exit 1; and only that message.
        if case .failed = outcome(1, message: "Fatal: something else") {} else { Issue.record("expected failed") }
        if case .failed = outcome(2, message: message) {} else { Issue.record("expected failed") }
    }

    @Test func otherExitCodesFailWithAReason() {
        for code: Int32 in [1, 2, 99, 255, -1, 4, 137] {
            guard case .failed(let c, let reason) = outcome(code, message: "Fatal: boom") else {
                Issue.record("exit \(code) was not a failure")
                continue
            }
            #expect(c == code)
            #expect(reason == "Fatal: boom")
        }
    }

    @Test func failureReasonFallsBackToTheFirstItemErrorThenTheExitCode() {
        #expect(outcome(1, errors: [item("/a")]) == .failed(exitCode: 1, reason: "open /a: permission denied"))
        #expect(outcome(2) == .failed(exitCode: 2, reason: "restic exited with status 2."))
    }

    @Test func exitCodesFromFixturesClassifyEndToEnd() throws {
        func parse(_ name: String) throws -> (summary: BackupSummary?, errors: [ResticItemError], exit: String?) {
            var summary: BackupSummary?, errors: [ResticItemError] = [], exit: String?
            for line in try Fixtures.lines(name) {
                switch ResticMessageParser.parse(line) {
                case .summary(let s): summary = s
                case .error(let e): errors.append(e)
                case .exitError(_, let m): exit = m
                default: break
                }
            }
            return (summary, errors, exit)
        }
        let creds = try parse("credentials-missing.stderr.ndjson")
        #expect(outcome(1, message: creds.exit) == .credentialsUnavailable)
        let pw = try parse("wrong-password.stderr.ndjson")
        #expect(outcome(12, message: pw.exit) == .wrongPassword)
        let unreadable = try parse("backup-unreadable.stderr.ndjson")
        #expect(outcome(3, errors: unreadable.errors, message: unreadable.exit) == .warning(unreadable: 1))
    }

    // MARK: JSON

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, _ expected: String) throws {
        #expect(try json(value) == expected)
        #expect(try JSONDecoder().decode(T.self, from: Data(expected.utf8)) == value)
    }

    @Test func outcomeJSONIsExplicit() throws {
        try roundTrip(RunOutcome.success(snapshotID: "abc"), #"{"snapshotID":"abc","type":"success"}"#)
        try roundTrip(RunOutcome.success(snapshotID: nil), #"{"type":"success"}"#)
        try roundTrip(RunOutcome.unchanged, #"{"type":"unchanged"}"#)
        try roundTrip(RunOutcome.warning(unreadable: 3), #"{"type":"warning","unreadable":3}"#)
        try roundTrip(RunOutcome.paused, #"{"type":"paused"}"#)
        try roundTrip(RunOutcome.cancelled, #"{"type":"cancelled"}"#)
        try roundTrip(RunOutcome.repositoryMissing, #"{"type":"repositoryMissing"}"#)
        try roundTrip(RunOutcome.wrongPassword, #"{"type":"wrongPassword"}"#)
        try roundTrip(RunOutcome.credentialsUnavailable, #"{"type":"credentialsUnavailable"}"#)
        try roundTrip(RunOutcome.locked, #"{"type":"locked"}"#)
        try roundTrip(RunOutcome.interrupted, #"{"type":"interrupted"}"#)
        try roundTrip(RunOutcome.skipped(.noNetwork), #"{"reason":{"type":"noNetwork"},"type":"skipped"}"#)
        try roundTrip(RunOutcome.failed(exitCode: 2, reason: "boom"),
                      #"{"exitCode":2,"reason":"boom","type":"failed"}"#)
    }

    @Test func skipReasonJSONIsExplicit() throws {
        try roundTrip(SkipReason.onBattery, #"{"type":"onBattery"}"#)
        try roundTrip(SkipReason.batteryBelow(20), #"{"percent":20,"type":"batteryBelow"}"#)
        try roundTrip(SkipReason.constrainedNetwork, #"{"type":"constrainedNetwork"}"#)
        try roundTrip(SkipReason.noNetwork, #"{"type":"noNetwork"}"#)
        try roundTrip(SkipReason.volumeNotMounted("Backup"), #"{"type":"volumeNotMounted","volume":"Backup"}"#)
        try roundTrip(SkipReason.agentUpdating, #"{"type":"agentUpdating"}"#)
    }

    /// The one wording of each skip, shared by the menu and the run log and alerts.
    @Test func skipReasonsReadAsSentences() {
        #expect(SkipReason.onBattery.summary == "Skipped while on battery")
        #expect(SkipReason.batteryBelow(20).summary == "Skipped: battery below 20 %")
        #expect(SkipReason.constrainedNetwork.summary == "Skipped on a low data network")
        #expect(SkipReason.noNetwork.summary == "Skipped: no network")
        #expect(SkipReason.volumeNotMounted("Backup").summary == "Skipped: Backup isn't connected")
        #expect(SkipReason.agentUpdating.summary == "Skipped: Restorey was updating")
    }

    @Test func triggerJSONIsAString() throws {
        try roundTrip(RunTrigger.scheduled, #""scheduled""#)
        try roundTrip(RunTrigger.catchUp, #""catchUp""#)
        try roundTrip(RunTrigger.manual, #""manual""#)
        try roundTrip(RunTrigger.retry, #""retry""#)
    }

    @Test func unknownTypesAreRefusedRatherThanGuessed() {
        for text in [#"{"type":"from_the_future"}"#, #"{"type":"skipped","reason":{"type":"x"}}"#, #"{"snapshotID":"a"}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(RunOutcome.self, from: Data(text.utf8)) }
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SkipReason.self, from: Data(#"{"type":"x"}"#.utf8)) }
    }
}
