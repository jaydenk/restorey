import Foundation
import Testing
@testable import RestoreyCore

/// The order of the calls that bring one of Restorey's windows forward, and the policy bookkeeping around closes and
/// alerts (O1 fix round 2, review M7), against a fake AppKit.
@MainActor
struct ActivationControllerTests {
    @MainActor
    final class FakeHost: ActivationHost {
        typealias Handle = String
        var calls: [String] = []
        var isActive = false
        var isHidden = false
        var visible: Set<String> = []
        var pending: [@MainActor () -> Void] = []

        func setPolicy(_ policy: AppPolicy) { calls.append("policy \(policy)") }
        func unhideWithoutActivation() {
            calls.append("unhide")
            isHidden = false
        }
        func orderFront(_ window: String) {
            calls.append("front \(window)")
            visible.insert(window)
        }
        func activate() { calls.append("activate") }
        func isVisible(_ window: String) -> Bool { !isHidden && visible.contains(window) }
        func orderFrontRegardless(_ window: String) { calls.append("regardless \(window)") }
        func nextTurn(_ body: @escaping @MainActor () -> Void) { pending.append(body) }

        func runNextTurn() {
            let bodies = pending
            pending = []
            bodies.forEach { $0() }
        }
    }

    private func make() -> (ActivationController<FakeHost>, FakeHost) {
        let host = FakeHost()
        return (ActivationController(host: host), host)
    }

    @Test func thePolicyComesBeforeTheWindowAndTheActivation() {
        let (controller, host) = make()
        controller.bringForward(.window(.restoreFiles), "restore")
        #expect(host.calls == ["policy regular", "front restore", "activate"])
    }

    @Test func anOpenAppDoesntSetThePolicyAgain() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        host.calls = []
        controller.bringForward(.window(.restoreFiles), "restore")
        #expect(host.calls == ["front restore", "activate"])
    }

    @Test func aRefusedActivationOrdersTheWindowFrontOnTheNextTurn() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        #expect(!host.calls.contains("regardless settings"))
        host.runNextTurn()
        #expect(host.calls.last == "regardless settings")
    }

    @Test func aGrantedActivationNeedsNoFallback() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        host.isActive = true
        host.runNextTurn()
        #expect(!host.calls.contains("regardless settings"))
    }

    @Test func aWindowClosedBeforeTheNextTurnIsLeftAlone() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        host.visible.remove("settings")
        controller.closed(.window(.settings))
        host.runNextTurn()
        #expect(!host.calls.contains("regardless settings"))
    }

    /// Review M3: a hidden app (⌘H) is shown again, without activating, before anything else, so a refused
    /// activation still leaves the window on screen.
    @Test func aHiddenAppIsShownBeforeTheWindowComesForward() {
        let (controller, host) = make()
        host.isHidden = true
        controller.bringForward(.window(.restoreFiles), "restore")
        #expect(host.calls == ["policy regular", "unhide", "front restore", "activate"])
        host.runNextTurn()
        #expect(host.calls.last == "regardless restore")
    }

    @Test func closingTheLastWindowGoesBackToTheMenuBar() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        controller.bringForward(.developer, "developer")
        host.calls = []
        controller.closed(.window(.settings))
        #expect(host.calls.isEmpty)
        controller.closed(.developer)
        #expect(host.calls == ["policy accessory"])
    }

    @Test func anAlertIsBracketedByThePolicy() {
        let (controller, host) = make()
        let response = controller.runModal("alert") { () -> Int in
            host.calls.append("run")
            return 1000
        }
        #expect(response == 1000)
        #expect(host.calls == ["policy regular", "activate", "run", "policy accessory"])
    }

    @Test func anAlertOverAnOpenWindowLeavesRestoreyAnOrdinaryApp() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        host.calls = []
        _ = controller.runModal("alert") { host.calls.append("run") }
        #expect(host.calls == ["activate", "run"])
    }

    /// A panel or the About window shown on its own is a window until it closes (review M2).
    @Test func aPanelKeepsRestoreyAnOrdinaryAppAfterItsWindowCloses() {
        let (controller, host) = make()
        controller.bringForward(.window(.settings), "settings")
        controller.shown(.about)
        host.calls = []
        controller.closed(.window(.settings))
        #expect(host.calls.isEmpty)
        controller.closed(.about)
        #expect(host.calls == ["policy accessory"])
    }
}
