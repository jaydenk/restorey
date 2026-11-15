import Foundation
import Testing
@testable import RestoreyCore

/// O1 (owner ruling): Restorey is an ordinary app (`.regular`: Dock icon, ⌘-Tab, its own menu bar) while any of its
/// windows is open, and a menu bar app (`.accessory`) once the last one closes. Whether Restorey is active when a
/// window closes doesn't change the decision.
struct WindowPresenceTests {
    @Test func theFirstWindowMakesRestoreyAnOrdinaryApp() {
        var presence = WindowPresence()
        #expect(presence.policy == .accessory)
        #expect(presence.shown(.window(.settings)) == .regular)
        #expect(presence.policy == .regular)
    }

    @Test func anotherWindowChangesNothing() {
        var presence = WindowPresence()
        presence.shown(.window(.settings))
        #expect(presence.shown(.window(.restoreFiles)) == nil)
        // The same window shown again (brought forward) changes nothing either.
        #expect(presence.shown(.window(.settings)) == nil)
    }

    @Test func closingOneOfTwoWindowsStaysAnOrdinaryApp() {
        var presence = WindowPresence()
        presence.shown(.window(.settings))
        presence.shown(.window(.recoveryKit))
        #expect(presence.closed(.window(.recoveryKit)) == nil)
        #expect(presence.policy == .regular)
    }

    @Test func closingTheLastWindowGoesBackToTheMenuBar() {
        var presence = WindowPresence()
        presence.shown(.window(.settings))
        presence.shown(.window(.recoveryKit))
        presence.closed(.window(.recoveryKit))
        #expect(presence.closed(.window(.settings)) == .accessory)
        #expect(presence.policy == .accessory)
    }

    /// The red close button pressed while another app is active: the decision is the same, so the Dock icon goes.
    @Test func closingTheLastWindowWhileInactiveStillGoesBackToTheMenuBar() {
        var presence = WindowPresence()
        presence.shown(.window(.settings))
        #expect(presence.closed(.window(.settings)) == .accessory)
    }

    @Test func theSetupWindowCountsLikeAnyOther() {
        var presence = WindowPresence()
        #expect(presence.shown(.window(.setup)) == .regular)
        presence.shown(.window(.settings))
        #expect(presence.closed(.window(.setup)) == nil)
        #expect(presence.closed(.window(.settings)) == .accessory)
    }

    @Test func theDeveloperWindowCountsLikeAnyOther() {
        var presence = WindowPresence()
        #expect(presence.shown(.developer) == .regular)
        presence.shown(.window(.settings))
        #expect(presence.closed(.window(.settings)) == nil)
        #expect(presence.closed(.developer) == .accessory)
    }

    /// An alert run on its own (the menu's "Restorey couldn't start the backup") is a window while it is up.
    @Test func anAlertCountsWhileItIsUp() {
        var presence = WindowPresence()
        let first = UUID()
        let second = UUID()
        #expect(presence.shown(.alert(first)) == .regular)
        presence.shown(.alert(second))
        #expect(presence.closed(.alert(first)) == nil)
        #expect(presence.closed(.alert(second)) == .accessory)
    }

    @Test func closingAWindowThatWasNeverShownChangesNothing() {
        var presence = WindowPresence()
        #expect(presence.closed(.window(.settings)) == nil)
        presence.shown(.window(.settings))
        #expect(presence.closed(.window(.restoreFiles)) == nil)
        #expect(presence.policy == .regular)
    }

    // MARK: The fallback when activation is refused

    @Test func aRefusedActivationOrdersTheWindowFrontAnyway() {
        #expect(WindowPresence.ordersFrontRegardless(isActive: false, windowVisible: true))
    }

    @Test func aGrantedActivationNeedsNoFallback() {
        #expect(!WindowPresence.ordersFrontRegardless(isActive: true, windowVisible: true))
    }

    /// Closed (or minimised) before the next turn: nothing is brought back.
    @Test func aWindowGoneByTheNextTurnIsLeftAlone() {
        #expect(!WindowPresence.ordersFrontRegardless(isActive: false, windowVisible: false))
    }
}
