import Foundation
import Testing
@testable import RestoreyCore

/// Fix rounds 3 and 4, N1/I1/M1/M2: after the owner approves a reveal, the window is waited for (key again, or a
/// short timeout), the secrets are fetched, and they show only if the window is still key and the opening that asked
/// is still open. These drive the window's key notifications, the prompt's answer, the window closing and the
/// fetch's completion in either order.
@MainActor
struct KeyWaiterTests {
    // MARK: The wait

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

    /// M2: a wait that ends early doesn't leave its timeout sleeping.
    @Test func aWaitThatEndsEarlyStopsItsTimeout() async {
        let waiter = KeyWaiter()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            waiter.becameKey()
        }
        #expect(await waiter.waitUntilKey(timeout: .seconds(60)))
        for _ in 0..<50 where waiter.runningTimeouts > 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(waiter.runningTimeouts == 0)
    }

    /// I1: `cancel` (the window closing) ends every wait at once, each exactly once, with false, and stops the timers.
    @Test func cancelResumesEveryWaiterOnceWithFalse() async {
        let waiter = KeyWaiter()
        let start = ContinuousClock.now
        let waits = (0..<3).map { _ in
            Task { @MainActor in await waiter.waitUntilKey(timeout: .seconds(60)) }
        }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        // A later key event or a second cancel resumes nothing again (a double resume would trap).
        waiter.becameKey()
        waiter.cancel()
        var results: [Bool] = []
        for wait in waits { results.append(await wait.value) }
        #expect(results == [false, false, false])
        #expect(ContinuousClock.now - start < .seconds(5))
        for _ in 0..<50 where waiter.runningTimeouts > 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(waiter.runningTimeouts == 0)
    }

    /// A cancel is for the waits in progress: the waiter still works for the next one.
    @Test func aWaitAfterACancelStillWorks() async {
        let waiter = KeyWaiter()
        waiter.cancel()
        waiter.becameKey()
        #expect(await waiter.waitUntilKey(timeout: .seconds(5)))
    }

    // MARK: The reveal's order

    /// The normal path: the prompt takes the key, it comes back after the prompt, then the fetch: shown.
    @Test func keyBackBeforeTheFetchShows() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var fetchedWhileKey: Bool?
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .seconds(5), isCurrent: { true },
            approve: {
                waiter.resignedKey()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(20))
                    waiter.becameKey()
                }
                return true
            },
            fetch: {
                fetchedWhileKey = waiter.isKey
                return true
            })
        #expect(fetchedWhileKey == true)
        #expect(show)
    }

    /// M1: the prompt's answer arrives before the window's resign-key notification. The window still reads as key,
    /// but it hasn't come back from the prompt yet, so the fetch waits for it: resign, then key again, then shown.
    @Test func aResignThatArrivesAfterTheAnswerIsWaitedOut() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var fetchedAfterReturn: Bool?
        var returned = false
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .seconds(5), isCurrent: { true },
            approve: {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(20))
                    waiter.resignedKey()
                    try? await Task.sleep(for: .milliseconds(20))
                    returned = true
                    waiter.becameKey()
                }
                return true
            },
            fetch: {
                fetchedAfterReturn = returned
                return true
            })
        #expect(fetchedAfterReturn == true)
        #expect(show)
    }

    /// Fix round 5: a prompt that never takes the key (the window stays key throughout). The wait times out, and
    /// by then any late resign has had the whole wait to arrive, so a window still key is shown (owner ruling:
    /// approving shows them at once).
    @Test func aPromptThatNeverTakesTheKeyShowsAfterTheTimeout() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var fetched = false
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .milliseconds(30), isCurrent: { true },
            approve: { true },
            fetch: {
                fetched = true
                return true
            })
        #expect(fetched)
        #expect(show)
    }

    /// M1, the other way: the resign arrives after the answer and the window never comes back in time. The fetch
    /// runs after the timeout (Copy needs the secrets) and nothing is shown.
    @Test func aLateResignWithNoReturnShowsDots() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var fetched = false
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .milliseconds(80), isCurrent: { true },
            approve: {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(10))
                    waiter.resignedKey()
                }
                return true
            },
            fetch: {
                fetched = true
                return true
            })
        #expect(fetched)
        #expect(!waiter.isKey)
        #expect(!show)
    }

    /// Without a prompt (already confirmed in this opening) there is no wait: a key window shows at once.
    @Test func noPromptNoWait() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        let start = ContinuousClock.now
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: false, timeout: .seconds(5), isCurrent: { true },
            approve: { true }, fetch: { true })
        #expect(show)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// A prompt made in this window doesn't leave it waiting for a return on the next, prompt-free reveal.
    @Test func theNextRevealWithoutAPromptIsntHeldByTheLastOne() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        _ = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .milliseconds(30), isCurrent: { true },
            approve: { true }, fetch: { true })
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: false, timeout: .zero, isCurrent: { true },
            approve: { true }, fetch: { true })
        #expect(show)
    }

    /// The owner switched away while the secrets were being fetched: dots (live check 26).
    @Test func resigningDuringTheFetchShowsNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: false, timeout: .zero, isCurrent: { true },
            approve: { true },
            fetch: {
                waiter.resignedKey()
                return true
            })
        #expect(!show)
    }

    @Test func aFailedFetchShowsNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        #expect(await !RevealOrder.reveal(
            waiter: waiter, prompts: false, timeout: .zero, isCurrent: { true }, approve: { true }, fetch: { false }))
    }

    @Test func aDeclinedPromptFetchesNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var fetched = false
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .seconds(5), isCurrent: { true },
            approve: { false },
            fetch: {
                fetched = true
                return true
            })
        #expect(!fetched)
        #expect(!show)
    }

    // MARK: I1: the window closes

    /// The window closes during the wait after the prompt: the wait ends at once, no fetch runs, nothing shows.
    @Test func closingDuringTheWaitFetchesNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var open = true
        var fetched = false
        let start = ContinuousClock.now
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .seconds(60), isCurrent: { open },
            approve: {
                waiter.resignedKey()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(20))
                    // What `close()` does: the opening ends, then the wait is cancelled.
                    open = false
                    waiter.cancel()
                }
                return true
            },
            fetch: {
                fetched = true
                return true
            })
        #expect(!fetched)
        #expect(!show)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The window closes while macOS asks: approved or not, nothing is fetched and there is no wait.
    @Test func closingDuringThePromptFetchesNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var open = true
        var fetched = false
        let start = ContinuousClock.now
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: true, timeout: .seconds(60), isCurrent: { open },
            approve: {
                open = false
                waiter.cancel()
                return true
            },
            fetch: {
                fetched = true
                return true
            })
        #expect(!fetched)
        #expect(!show)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The window closes while the secrets are on their way: they aren't shown (the fetch's own opening check
    /// drops them).
    @Test func closingDuringTheFetchShowsNothing() async {
        let waiter = KeyWaiter()
        waiter.becameKey()
        var open = true
        let show = await RevealOrder.reveal(
            waiter: waiter, prompts: false, timeout: .zero, isCurrent: { open },
            approve: { true },
            fetch: {
                open = false
                waiter.cancel()
                return true
            })
        #expect(!show)
    }
}
