import Testing

@testable import RestoreyCore

struct CheckInTests {
    private let redactor = Redactor(secrets: ["s3cret"])

    @Test func startPing() {
        #expect(pingsAtStart(trigger: .scheduled) == [.start])
        #expect(pingsAtStart(trigger: .manual) == [.start])
    }

    @Test func pingTable() {
        func ping(_ outcome: RunOutcome) -> CheckInPing? {
            pingAtEnd(outcome: outcome, logTail: [], redactor: redactor)
        }
        #expect(ping(.success(snapshotID: "abc")) == .success)
        #expect(ping(.unchanged) == .success)
        #expect(ping(.warning(unreadable: 2)) == .success)
        #expect(ping(.failed(exitCode: 1, reason: "x")) == .fail(body: "restic exit code 1\n"))
        #expect(ping(.wrongPassword) == .fail(body: "restic exit code 12\n"))
        #expect(ping(.repositoryMissing) == .fail(body: "restic exit code 10\n"))
        #expect(ping(.credentialsUnavailable) == .fail(body: "restic exit code 1\n"))
        #expect(ping(.interrupted) == .fail(body: "interrupted\n"))
        #expect(ping(.paused) == nil)
        #expect(ping(.cancelled) == nil)
        #expect(ping(.locked) == nil)
        #expect(ping(.skipped(.onBattery)) == nil)
        #expect(ping(.skipped(.volumeNotMounted("Backup"))) == nil)
    }

    @Test func failBodyCarriesExitCodeAndRedactedTail() {
        let tail = (1...30).map { "line \($0)" } + ["token=s3cret at https://u:p@host/x"]
        let ping = pingAtEnd(outcome: .failed(exitCode: 2, reason: "x"), logTail: tail, redactor: redactor)
        guard case .fail(let body)? = ping else {
            Issue.record("expected a fail ping")
            return
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "restic exit code 2")
        let tailLines = Array(lines.dropFirst())
        #expect(tailLines.count == 20)
        #expect(tailLines.first == "line 12")
        #expect(tailLines.last == "token=[redacted] at https://[redacted]@host/x")
        #expect(!body.contains("s3cret"))
    }

    @Test func shortTailIsKeptWhole() {
        let ping = pingAtEnd(outcome: .wrongPassword, logTail: ["a", "b"], redactor: redactor)
        #expect(ping == .fail(body: "restic exit code 12\na\nb"))
    }
}
