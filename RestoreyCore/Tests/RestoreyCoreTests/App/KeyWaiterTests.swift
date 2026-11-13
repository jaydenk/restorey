import Foundation
import Testing
@testable import RestoreyCore

/// Fix round 3, N1: after the owner approves a reveal, the window is waited for (key again, or a short timeout), the
/// secrets are fetched, and they show only if the window is still key. These drive the window's key notifications
/// and the fetch's completion in either order.
@MainActor
struct KeyWaiterTests {
    @Test func aKeyWindowNeedsNoWait() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        #expect(await waiter.waitUntilKey(timeout: .seconds(5)))
    }

    @Test func theWaitEndsWhenTheWindowBecomesKey() async {
        let waiter = KeyWaiter()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            waiter.becameKey()
        }
        let start = ContinuousClock.now
        #expect(await waiter.waitUntilKey(timeout: .seconds(5)))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func theWaitGivesUpAfterTheTimeout() async {
        let waiter = KeyWaiter()
        #expect(await !waiter.waitUntilKey(timeout: .milliseconds(30)))
        #expect(!waiter.isKey)
    }

    /// The normal path: key comes back after the prompt, then the fetch: shown.
    @Test func keyBeforeTheFetchEndsShows() async {
        let waiter = KeyWaiter()
        var fetchedWhileKey: Bool?
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            waiter.becameKey()
        }
        let show = await RevealOrder.afterApproval(waiter: waiter, timeout: .seconds(5)) {
            fetchedWhileKey = waiter.isKey
            return true
        }
        #expect(fetchedWhileKey == true)
        #expect(show)
    }

    /// The owner switched away while the secrets were being fetched: dots (live check 26).
    @Test func resigningDuringTheFetchShowsNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        let show = await RevealOrder.afterApproval(waiter: waiter, timeout: .seconds(5)) {
            waiter.resignedKey()
            return true
        }
        #expect(!show)
    }

    /// The window never came back: the fetch still runs (Copy needs the secrets), nothing is shown.
    @Test func aWindowThatNeverBecomesKeyShowsNothing() async {
        let waiter = KeyWaiter()
        var fetched = false
        let show = await RevealOrder.afterApproval(waiter: waiter, timeout: .milliseconds(30)) {
            fetched = true
            return true
        }
        #expect(fetched)
        #expect(!show)
    }

    @Test func aFailedFetchShowsNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        #expect(await !RevealOrder.afterApproval(waiter: waiter, timeout: .seconds(1)) { false })
    }
}
