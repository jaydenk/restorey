import Foundation
import Synchronization
import Testing

@testable import RestoreyCore

/// `CheckInService` against a real HTTP server on 127.0.0.1. Back-off is zero unless a test says
/// otherwise, so the retry tests take milliseconds.
@Suite(.serialized)
struct CheckInServiceTests {
    private let planID = UUID()

    /// Every line the service logged, with whether it was logged as a failure.
    final class LogLines: Sendable {
        private let lines = Mutex<[(text: String, failure: Bool)]>([])
        var all: [(text: String, failure: Bool)] { lines.withLock { $0 } }
        var function: @Sendable (String, CheckInService.LogLevel) -> Void {
            { text, level in self.lines.withLock { $0.append((text, level == .error)) } }
        }
    }

    private func service(
        _ server: StubHTTPServer?, path: String = "/abc", session: URLSession = CheckInService.makeSession(),
        retryDelays: [Duration] = [.zero, .zero, .zero], budget: Duration = CheckInService.sendBudget,
        log: LogLines = LogLines(), results: Results = Results(), baseURL: String? = nil
    ) throws -> CheckInService {
        let secrets = InMemorySecretStore()
        if let base = baseURL ?? server?.baseURL { try secrets.write(base + path, for: .checkInURL(planID)) }
        return CheckInService(
            secrets: secrets, session: session, retryDelays: retryDelays, budget: budget, log: log.function,
            onResult: results.function)
    }

    /// Every `(plan, HTTP status)` the service reported.
    final class Results: Sendable {
        private let items = Mutex<[(UUID, Int)]>([])
        var statuses: [Int] { items.withLock { $0.map(\.1) } }
        var plans: [UUID] { items.withLock { $0.map(\.0) } }
        var function: @Sendable (UUID, Int) async -> Void {
            { id, status in self.items.withLock { $0.append((id, status)) } }
        }
    }

    /// Success goes to the URL, a failure to `/fail`; there is no `/start` ping (Ruling R57).
    @Test func successAndFailPaths() async throws {
        let server = try StubHTTPServer()
        defer { server.stop() }
        let checkIn = try service(server)
        await checkIn.send(.success, planID: planID)
        await checkIn.send(.fail(body: "restic exit code 1\n"), planID: planID)
        #expect(server.requests.map(\.path) == ["/abc", "/abc/fail"])
        #expect(server.requests.map(\.method) == ["POST", "POST"])
    }

    /// The success ping goes to the URL exactly as stored; `/fail` adds one `/` and its suffix.
    @Test func aTrailingSlashOnTheURLIsNotDoubled() async throws {
        let server = try StubHTTPServer()
        defer { server.stop() }
        let checkIn = try service(server, path: "/abc/")
        await checkIn.send(.fail(body: "x"), planID: planID)
        await checkIn.send(.success, planID: planID)
        #expect(server.requests.map(\.path) == ["/abc/fail", "/abc/"])
    }

    @Test func failBodyIsSent() async throws {
        let server = try StubHTTPServer()
        defer { server.stop() }
        let checkIn = try service(server)
        let body = "restic exit code 3\nFatal: unable to open config file — no such file\n"
        await checkIn.send(.fail(body: body), planID: planID)
        await checkIn.send(.success, planID: planID)
        let requests = server.requests
        try #require(requests.count == 2)
        #expect(requests[0].body == Data(body.utf8))
        #expect(requests[0].headers["content-type"] == "text/plain; charset=utf-8")
        #expect(requests[1].body.isEmpty)
    }

    @Test func retriesOn503ThenSucceeds() async throws {
        let server = try StubHTTPServer(script: [.status(503), .status(503)])
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(server, log: log)
        await checkIn.send(.success, planID: planID)
        #expect(server.requests.count == 3)
        #expect(log.all.map(\.text) == ["check-in ping success for \(planID.uuidString): sent (HTTP 200)"])
    }

    @Test func givesUpAfterThreeRetries() async throws {
        let server = try StubHTTPServer(script: Array(repeating: .status(500), count: 10))
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(server, log: log)
        await checkIn.send(.success, planID: planID)
        #expect(server.requests.count == 4)
        #expect(log.all.map(\.text) == ["check-in ping success for \(planID.uuidString): failed after 4 attempts (HTTP 500)"])
        #expect(log.all.map(\.failure) == [true])
    }

    @Test func noRetryOn404() async throws {
        let server = try StubHTTPServer(script: [.status(404)])
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(server, log: log)
        await checkIn.send(.fail(body: "x"), planID: planID)
        #expect(server.requests.count == 1)
        #expect(log.all.map(\.text) == ["check-in ping fail for \(planID.uuidString): failed (HTTP 404), not retried"])
    }

    @Test func transportErrorsAreRetried() async throws {
        // A port that was bound and released, so nothing listens on it: every attempt is refused.
        let port = try freeLocalPort()
        let log = LogLines()
        let results = Results()
        let checkIn = try service(nil, log: log, results: results, baseURL: "http://127.0.0.1:\(port)")
        await checkIn.send(.success, planID: planID)
        let line = try #require(log.all.first?.text)
        #expect(line.hasPrefix("check-in ping success for \(planID.uuidString): failed after 4 attempts ("))
        #expect(results.statuses.isEmpty)
    }

    @Test func theResultIsReportedFor2xxAnd4xxOnly() async throws {
        let server = try StubHTTPServer(script: [.status(404), .status(200)] + Array(repeating: .status(503), count: 4))
        defer { server.stop() }
        let results = Results()
        let checkIn = try service(server, results: results)
        await checkIn.send(.success, planID: planID)
        await checkIn.send(.success, planID: planID)
        await checkIn.send(.success, planID: planID)
        #expect(results.statuses == [404, 200])
        #expect(results.plans == [planID, planID])
    }

    /// The server takes every request and never replies: each attempt ends at the session's resource
    /// timeout and is retried. The real session's 30 s and 60 s timeouts would make this a two-minute
    /// test, so this one uses 1 s and 2 s; `realSessionTimeouts` checks the real values.
    @Test func timeoutDoesNotHang() async throws {
        let server = try StubHTTPServer(script: Array(repeating: .hang, count: 4))
        defer { server.stop() }
        let log = LogLines()
        let session = CheckInService.makeSession(requestTimeout: 1, resourceTimeout: 2)
        let checkIn = try service(server, session: session, log: log)
        let elapsed = await ContinuousClock().measure { await checkIn.send(.success, planID: planID) }
        #expect(elapsed < .seconds(4 * 2 + 3))
        #expect(server.requests.count == 4)
        #expect(log.all.map(\.text) == ["check-in ping success for \(planID.uuidString): failed after 4 attempts (timed out)"])
    }

    /// With the real 30 s and 60 s timeouts, the send budget is what ends a hung send.
    @Test func theBudgetEndsAHungSend() async throws {
        let server = try StubHTTPServer(script: [.hang])
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(server, budget: .seconds(1), log: log)
        let elapsed = await ContinuousClock().measure { await checkIn.send(.success, planID: planID) }
        #expect(elapsed < .seconds(3))
        #expect(server.requests.count == 1)
        #expect(log.all.map(\.text) == ["check-in ping success for \(planID.uuidString): failed after 1 attempt (no reply in time)"])
    }

    /// A retry whose back-off would end after the budget is not made.
    @Test func aRetryThatWouldOverrunTheBudgetIsSkipped() async throws {
        let server = try StubHTTPServer(script: [.status(503)])
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(server, retryDelays: [.seconds(30)], budget: .seconds(5), log: log)
        let elapsed = await ContinuousClock().measure { await checkIn.send(.success, planID: planID) }
        #expect(elapsed < .seconds(2))
        #expect(server.requests.count == 1)
        #expect(log.all.map(\.text) == [
            "check-in ping success for \(planID.uuidString): failed after 1 attempt (HTTP 503), no time left to retry",
        ])
    }

    @Test func missingURLSendsNothing() async throws {
        let server = try StubHTTPServer()
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(nil, log: log)
        await checkIn.send(.success, planID: planID)
        await checkIn.send(.fail(body: "x"), planID: planID)
        #expect(server.requests.isEmpty)
        #expect(log.all.isEmpty)
    }

    @Test func anInvalidURLIsLoggedWithoutTheURL() async throws {
        let secrets = InMemorySecretStore()
        try secrets.write("ftp://hc.example/secret-token", for: .checkInURL(planID))
        let log = LogLines()
        let checkIn = CheckInService(secrets: secrets, session: CheckInService.makeSession(), log: log.function)
        await checkIn.send(.success, planID: planID)
        #expect(log.all.map(\.text) == [
            "check-in ping success for \(planID.uuidString): not sent, the check-in URL isn't an http or https address",
        ])
    }

    @Test func theLogNeverNamesTheURL() async throws {
        let server = try StubHTTPServer(script: [.status(503), .status(404)])
        defer { server.stop() }
        let log = LogLines()
        let checkIn = try service(server, path: "/secret-token", log: log)
        await checkIn.send(.success, planID: planID)
        await checkIn.send(.success, planID: planID)
        #expect(log.all.count == 2)
        for line in log.all.map(\.text) {
            #expect(!line.contains("secret-token"))
            #expect(!line.contains("127.0.0.1"))
        }
    }

    @Test func realSessionTimeouts() {
        let session = CheckInService.makeSession()
        #expect(session !== URLSession.shared)
        #expect(session.configuration.timeoutIntervalForRequest == 30)
        #expect(session.configuration.timeoutIntervalForResource == 60)
        // Ephemeral: nothing about the pings is cached or kept on disk.
        #expect(session.configuration.urlCache?.diskCapacity ?? 0 == 0)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// 5 s, 30 s and 120 s of back-off plus every attempt must fit the agent's 180 s drain budget.
    @Test func theWorstCaseFitsTheDrainBudget() {
        #expect(CheckInService.retryDelays == [.seconds(5), .seconds(30), .seconds(120)])
        #expect(CheckInService.sendBudget < .seconds(180))
    }
}
