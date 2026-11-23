import Foundation
@testable import AgentCore

/// A notification centre that records what it is given, and answers authorisation as told.
actor FakeNotifier: AlertNotifying {
    struct Refused: Error {}
    private(set) var posted: [AlertContent] = []
    /// The identifiers removed, in order.
    private(set) var removed: [String] = []
    var authorised: Bool?
    var refuse = false

    init(authorised: Bool?) { self.authorised = authorised }

    func authorisationStatus() async -> Bool? { authorised }

    func post(_ alert: AlertContent) async throws {
        if refuse { throw Refused() }
        posted.append(alert)
    }

    func remove(identifiers: [String]) async {
        removed.append(contentsOf: identifiers)
    }

    func set(authorised: Bool?) { self.authorised = authorised }
    func set(refuse: Bool) { self.refuse = refuse }
    var titles: [String] { posted.map(\.title) }
    /// What was posted for backups starting and finishing, not for problems.
    var events: [AlertContent] { posted.filter { $0.identifier.hasPrefix("event.") } }
}
