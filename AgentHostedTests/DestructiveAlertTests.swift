import AppKit
import Foundation
import Testing
@testable import RestoreyCore

/// Fix round 2 (L1): the earlier-snapshots confirmation's buttons. `DestructiveAlert` is app code, compiled into this
/// bundle (project.yml) because the app has no test target of its own; the text-length guard (L3) stays in RestoreyCore.
@MainActor
struct DestructiveAlertTests {
    /// The longest confirmation setup can show: a long host name, four-digit counts, prune off.
    private static let longest = EarlierSnapshotsText.confirmation(
        EarlierSnapshotGroup(
            scope: .beforeAdoption, host: "jaydens-macbook-pro-16-inch-2026", paths: ["/Users/x/Documents"], tags: [],
            keptCount: 1234, removeIDs: (0..<4321).map { String(format: "%064d", $0) }),
        pruneEnabled: false, afterFirstBackup: true, home: "/Users/x")

    @Test func cancelIsTheReturnDefaultAndRemoveIsNeverADefault() {
        let built = DestructiveAlert.make(Self.longest)
        #expect(built.alert.buttons.first === built.cancel, "Cancel is added first, so NSAlert treats it as the cancel button")
        #expect(built.cancel.keyEquivalent == "\r")
        #expect(built.remove.keyEquivalent != "\r" && built.remove.keyEquivalent != "\u{1b}")
        #expect(built.remove.hasDestructiveAction)
        #expect(!built.cancel.hasDestructiveAction)
        #expect(built.remove.title == "Remove 4321 Snapshots")
    }
}
