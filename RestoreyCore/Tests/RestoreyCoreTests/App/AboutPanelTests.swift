import Foundation
import Testing
@testable import RestoreyCore

/// Picking out the standard About panel once AppKit has shown it (Task 14c, build 816 finding). AppKit gives the
/// panel an identifier of its own ("_NS:149" on macOS 27.2), so it can't be told apart by having none.
struct AboutPanelTests {
    private static let own: Set<String> = Set(AppWindowKind.allCases.map(\.rawValue))

    @Test func thePanelIsTheWindowThatJustAppeared() {
        let before = [WindowSnapshot(number: 10, identifier: "settings", isVisible: true)]
        let after = before + [WindowSnapshot(number: 11, identifier: "_NS:149", isVisible: true)]
        #expect(AboutPanel.find(before: before, after: after, ownIdentifiers: Self.own) == 11)
    }

    @Test func aWindowWithNoIdentifierCountsToo() {
        let after = [WindowSnapshot(number: 11, identifier: nil, isVisible: true)]
        #expect(AboutPanel.find(before: [], after: after, ownIdentifiers: Self.own) == 11)
    }

    @Test func oneOfRestoreysOwnWindowsIsNeverThePanel() {
        let after = [WindowSnapshot(number: 12, identifier: "restoreFiles", isVisible: true)]
        #expect(AboutPanel.find(before: [], after: after, ownIdentifiers: Self.own) == nil)
    }

    @Test func aWindowAlreadyOnScreenIsntThePanel() {
        let window = WindowSnapshot(number: 13, identifier: "_NS:149", isVisible: true)
        #expect(AboutPanel.find(before: [window], after: [window], ownIdentifiers: Self.own) == nil)
    }

    /// A panel that was hidden (Restorey deactivated) and is shown again is new on screen, so it is found again.
    @Test func aWindowHiddenBeforeIsFoundOnceShown() {
        let hidden = WindowSnapshot(number: 14, identifier: "_NS:149", isVisible: false)
        let shown = WindowSnapshot(number: 14, identifier: "_NS:149", isVisible: true)
        #expect(AboutPanel.find(before: [hidden], after: [shown], ownIdentifiers: Self.own) == 14)
    }

    @Test func nothingNewOnScreenIsNoPanel() {
        let hidden = WindowSnapshot(number: 15, identifier: nil, isVisible: false)
        #expect(AboutPanel.find(before: [], after: [hidden], ownIdentifiers: Self.own) == nil)
    }

    /// Hidden by deactivation is still open: only a close ends the count (`WindowPresence`).
    @Test func aHiddenPanelStillCounts() {
        var presence = WindowPresence()
        presence.shown(.about)
        // Hiding posts no close, so nothing is reported: the presence is unchanged.
        #expect(presence.policy == .regular)
        #expect(presence.closed(.about) == .accessory)
    }
}
