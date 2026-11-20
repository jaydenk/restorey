import Foundation
import Testing
@testable import RestoreyCore

/// The default folder list's revisions (owner, 20 Nov 2026): what each one added, so the agent can add a later default
/// to a plan made before it, once.
struct DefaultExclusionsTests {
    private static let home = URL(fileURLWithPath: "/Users/me")

    @Test func revisionTwoAddsTheCoreSpeechCaches() {
        #expect(DefaultExclusions.revision == 2)
        #expect(DefaultExclusions.additions(after: 1, home: Self.home)
            == ["/Users/me/Library/Group Containers/group.com.apple.CoreSpeech/Caches"])
    }

    @Test func thereIsNothingAfterTheCurrentRevision() {
        #expect(DefaultExclusions.additions(after: DefaultExclusions.revision, home: Self.home).isEmpty)
        #expect(DefaultExclusions.additions(after: DefaultExclusions.revision + 1, home: Self.home).isEmpty)
    }

    /// The two lists can't drift: every pattern a revision adds is in the list a new plan starts with, and the newest
    /// revision adds something (so `revision` was moved on with the last addition).
    @Test func everyAdditionIsADefault() {
        let paths = DefaultExclusions.paths(home: Self.home)
        for revision in 0..<DefaultExclusions.revision {
            for pattern in DefaultExclusions.additions(after: revision, home: Self.home) {
                #expect(paths.contains(pattern), "\(pattern) (after revision \(revision))")
            }
        }
        #expect(!DefaultExclusions.additions(after: DefaultExclusions.revision - 1, home: Self.home).isEmpty)
    }

    /// The home path is escaped as `paths(home:)` escapes it.
    @Test func additionsEscapeTheHomeFolder() {
        let home = URL(fileURLWithPath: "/Users/x[1]")
        #expect(DefaultExclusions.additions(after: 1, home: home)
            == ["/Users/x\\[1\\]/Library/Group Containers/group.com.apple.CoreSpeech/Caches"])
    }
}
