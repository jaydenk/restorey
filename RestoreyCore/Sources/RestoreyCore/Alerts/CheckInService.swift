import Foundation

/// Sends a plan's check-in pings to its Healthchecks-style URL (spec §6.2): `.start` to `<url>/start`,
/// `.success` to `<url>`, and `.fail` to `<url>/fail` with its body as `text/plain; charset=utf-8`.
/// Every ping is a POST; only `/fail` has a body.
///
/// The URL is read from the keychain when the ping is sent, so a changed URL takes effect at once. A
/// plan with no URL sends nothing and logs nothing.
///
/// A transport error or a 5xx is retried up to 3 times, after 5 s, 30 s and 120 s; a 4xx (or any other
/// non-2xx) is not. A ping that fails is logged and never fails the run. The log names the ping and the
/// plan, never the URL, which is a secret: "check-in ping <kind> for <plan id>: <outcome>".
///
/// **Worst case.** Each attempt is bounded by the session's resource timeout (60 s), so four attempts
/// and their back-off could take 4 × 60 + 5 + 30 + 120 = 395 s, more than the 180 s the agent gives
/// queued pings when it drains (`AgentState.prepareForRestart`). Every send therefore also has a
/// budget, `sendBudget` (170 s): an attempt still running when it runs out is cancelled, and a retry
/// whose back-off would end after it is not made. One send takes at most 170 s, plus the moment it
/// takes to cancel. Retries that fail fast (connection refused, a prompt 503) still get all four
/// attempts: 155 s of back-off. An attempt that hangs until the 30 s request timeout gets three.
public actor CheckInService: CheckInSending {
    public enum LogLevel: Sendable, Equatable {
        case info, error
    }

    /// The back-off before each retry.
    public static let retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
    /// How long one send may take in all, attempts and back-off together. Below the agent's 180 s drain.
    public static let sendBudget: Duration = .seconds(170)

    private let secrets: any SecretStore
    private let session: URLSession
    private let retryDelays: [Duration]
    private let budget: Duration
    private let log: @Sendable (String, LogLevel) -> Void

    /// - Parameters:
    ///   - session: `makeSession()` in the agent. Never `URLSession.shared`, whose resource timeout is 7 days.
    ///   - retryDelays, budget: injectable so tests need not wait minutes.
    ///   - log: one line per ping, for the agent's log.
    public init(
        secrets: any SecretStore, session: URLSession, retryDelays: [Duration] = CheckInService.retryDelays,
        budget: Duration = CheckInService.sendBudget,
        log: @escaping @Sendable (String, LogLevel) -> Void = { _, _ in }
    ) {
        self.secrets = secrets
        self.session = session
        self.retryDelays = retryDelays
        self.budget = budget
        self.log = log
    }

    /// An ephemeral session (no cookies, cache or credentials kept) with a 30 s request timeout and a
    /// 60 s resource timeout. The parameters are for tests.
    public static func makeSession(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    public func send(_ ping: CheckInPing, planID: UUID) async {
        let kind: String
        let suffix: String?
        switch ping {
        case .start: (kind, suffix) = ("start", "start")
        case .success: (kind, suffix) = ("success", nil)
        case .fail: (kind, suffix) = ("fail", "fail")
        }
        func note(_ outcome: String, _ level: LogLevel = .error) {
            log("check-in ping \(kind) for \(planID.uuidString): \(outcome)", level)
        }

        let stored: String?
        do {
            stored = try secrets.read(.checkInURL(planID))
        } catch {
            // The error names the keychain status, never a value.
            note("not sent, couldn't read the check-in URL from the Keychain (\(error))")
            return
        }
        guard let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else { return }
        guard let url = Self.url(stored, appending: suffix) else {
            note("not sent, the check-in URL isn't an http or https address")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if case .fail(let body) = ping {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        var attempts = 0
        while true {
            attempts += 1
            let result = await attempt(request, until: deadline)
            let tried = attempts == 1 ? "1 attempt" : "\(attempts) attempts"
            switch result {
            case .delivered(let status):
                note("sent (HTTP \(status))", .info)
                return
            case .rejected(let status):
                note("failed (HTTP \(status)), not retried")
                return
            case .retryable(let reason):
                guard attempts <= retryDelays.count else {
                    note("failed after \(tried) (\(reason))")
                    return
                }
                let delay = retryDelays[attempts - 1]
                guard clock.now.advanced(by: delay) < deadline else {
                    note(clock.now < deadline
                        ? "failed after \(tried) (\(reason)), no time left to retry"
                        : "failed after \(tried) (\(reason))")
                    return
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    note("failed after \(tried) (\(reason)), stopped before retrying")
                    return
                }
            }
        }
    }

    // MARK: Attempts

    private enum Attempt: Sendable {
        case delivered(Int)
        /// A 4xx or another answer that retrying won't change.
        case rejected(Int)
        case retryable(String)
    }

    /// One request, cancelled if it is still running at `deadline`.
    private func attempt(_ request: URLRequest, until deadline: ContinuousClock.Instant) async -> Attempt {
        let session = session
        return await withTaskGroup(of: Attempt?.self) { group in
            group.addTask {
                do {
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { return .retryable("not an HTTP response") }
                    switch http.statusCode {
                    case 200..<300: return .delivered(http.statusCode)
                    case 500...: return .retryable("HTTP \(http.statusCode)")
                    default: return .rejected(http.statusCode)
                    }
                } catch let error as URLError {
                    return .retryable(Self.describe(error))
                } catch {
                    return .retryable("\(type(of: error))")
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return nil
                }
                return .retryable("no reply in time")
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .retryable("cancelled")
        }
    }

    /// A short reason for the log. Never `localizedDescription` or `userInfo`, which can carry the URL.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "timed out"
        case .cannotConnectToHost: "couldn't connect"
        case .cannotFindHost, .dnsLookupFailed: "couldn't find the server"
        case .notConnectedToInternet, .networkConnectionLost: "no network connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "the secure connection failed"
        case .cancelled: "cancelled"
        default: "network error \(error.code.rawValue)"
        }
    }

    /// The stored URL with `/<suffix>` added to its path, keeping any query. Nil unless http or https.
    static func url(_ stored: String, appending suffix: String?) -> URL? {
        guard var components = URLComponents(string: stored),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else { return nil }
        if let suffix {
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            components.percentEncodedPath = path + "/" + suffix
        }
        return components.url
    }
}
