import Foundation
import Testing
@testable import RestoreyCore

/// Fix round 2 (L3): the earlier-snapshots confirmation's size. (Its buttons are tested with the app's
/// `DestructiveAlert`, in AgentHostedTests.)
struct EarlierSnapshotsConfirmationLengthTests {
    /// The longest confirmation setup can show: a long host name, four-digit counts, prune off.
    private static let longest = EarlierSnapshotsText.confirmation(
        EarlierSnapshotGroup(
            scope: .beforeAdoption, host: "jaydens-macbook-pro-16-inch-2026", paths: ["/Users/x/Documents"], tags: [],
            keptCount: 1234, removeIDs: (0..<4321).map { String(format: "%064d", $0) }),
        pruneEnabled: false, afterFirstBackup: true, home: "/Users/x")

    /// L3: the sheet's height comes from how many lines the text wraps to in macOS's narrow alert column, which a
    /// test can't lay out (an alert that isn't on screen lays out in the old wide style), so the guard is the text's
    /// length: the longest confirmation (a 32-character host name, four-digit counts) stays under 240 characters, about half the first wording, and its title short.
    @Test func theLongestConfirmationStaysShort() {
        #expect(Self.longest.message.count <= 240, "\(Self.longest.message.count): \(Self.longest.message)")
        #expect(Self.longest.title.count <= 50, "\(Self.longest.title)")
        let previous = EarlierSnapshotsText.confirmation(
            EarlierSnapshotGroup(
                scope: .previousFolderList(paths: ["/Users/x/Documents/Projects", "/Users/x/Pictures"]), host: "h",
                paths: ["/Users/x/Documents/Projects", "/Users/x/Pictures"], tags: [], keptCount: 1,
                removeIDs: ["a"]),
            pruneEnabled: false, afterFirstBackup: false, home: "/Users/x")
        #expect(previous.message.count <= 240)
    }
}
