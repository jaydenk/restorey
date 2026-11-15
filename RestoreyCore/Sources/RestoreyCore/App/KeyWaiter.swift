import Foundation

/// Whether a window is the key window, fed by its key notifications (`becameKey`, `resignedKey`), with a wait for
/// it to become key. Restore Files and the kit window use it after a Touch ID or password prompt: the prompt takes
/// the key window, and the window that asked gets it back only once macOS gives the front back to Restorey when
/// the prompt goes, which happens asynchronously (fix round 3, N1; O1 fix round).
///
/// During a prompt (`RevealOrder` brackets it) the window counts as back only once it has resigned key and become
/// key again (fix round 4, M1). The prompt's answer and the window's resign-key notification come from different
/// processes, so the answer can arrive first, while the window (and AppKit itself: the notification is posted as the
/// window's state changes) still reads as key. Waiting for the resign and the return, not for "key now", covers both
/// orders. If the prompt never takes the key, the wait times out; by then any late resign has had the whole wait to
/// arrive, so the reveal decides from `isKey` (fix round 5).
@MainActor
public final class KeyWaiter {
    /// The window's key state as last reported.
    public private(set) var isKey = false

    private enum Prompt {
        /// No prompt in progress: back means key.
        case none
        /// A prompt started while the window was key; its resign-key hasn't been seen yet.
        case shown
        /// The window resigned key after the prompt started (or wasn't key when it did): the next become-key is
        /// the return.
        case away
    }

    private var prompt = Prompt.none
    /// Which prompt `prompt` belongs to, so a sequence that ends late can't clear a newer one's.
    private var promptNumber = 0

    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    private var waiters: [UUID: Waiter] = [:]
    /// Timeout tasks still sleeping (for tests: one that ended early must stop, fix round 4, M2).
    private(set) var runningTimeouts = 0

    public init() {}

    /// Key, and if a prompt is in progress, key again since the prompt took it.
    var isBack: Bool { isKey && prompt == .none }

    public func becameKey() {
        isKey = true
        if prompt == .away { prompt = .none }
        if isBack { resumeAll(returning: true) }
    }

    public func resignedKey() {
        isKey = false
        if prompt == .shown { prompt = .away }
    }

    /// Ends every wait in progress at once, each with false: the window closed, or the opening that waited ended
    /// (fix round 4, I1). The prompt in progress, if any, is forgotten. Later waits work as usual.
    public func cancel() {
        prompt = .none
        resumeAll(returning: false)
    }

    /// True once the window is back (at once if it already is); false after `timeout` without it, or on `cancel`.
    public func waitUntilKey(timeout: Duration) async -> Bool {
        if isBack { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            runningTimeouts += 1
            let timer = Task { @MainActor in
                let expired = (try? await Task.sleep(for: timeout)) != nil
                self.runningTimeouts -= 1
                if expired { self.waiters.removeValue(forKey: id)?.continuation.resume(returning: false) }
            }
            waiters[id] = Waiter(continuation: continuation, timeout: timer)
        }
    }

    /// A prompt is about to take the key window. Returns its number, for `promptEnded`.
    func promptStarted() -> Int {
        promptNumber += 1
        prompt = isKey ? .shown : .away
        return promptNumber
    }

    /// The sequence that started prompt `number` is over: a later reveal without a prompt isn't held by it.
    func promptEnded(_ number: Int) {
        if number == promptNumber { prompt = .none }
    }

    private func resumeAll(returning value: Bool) {
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: value)
        }
    }
}

/// The order of a reveal the owner asked for with the button (fix rounds 3 and 4, N1/I1/M1): ask for the owner,
/// wait for the window to be back from the prompt (or `timeout`), fetch the secrets, then show them only if the
/// window is still key. Fetching first would usually finish before macOS gives the window back, and the approval
/// would be lost; checking after the fetch keeps an owner who switched away from finding the secrets shown when
/// they come back.
///
/// `isCurrent` says whether the opening that asked is still open (the window not closed, the plan not changed). It
/// is checked after the prompt, after the wait and after the fetch, so a closed opening never fetches and never
/// shows. Closing should also `cancel` the waiter, so the wait ends at once rather than at its timeout.
@MainActor
public enum RevealOrder {
    /// Whether to show the secrets.
    /// - prompts: whether `approve` will show a prompt (the owner wasn't yet confirmed in this opening). Without
    ///   one there is no wait.
    /// - approve: asks for the owner; true once confirmed.
    /// - fetch: returns whether the secrets arrived. It runs even if the window doesn't come back in time, since a
    ///   copy needs them anyway, but never once the opening has ended.
    public static func reveal(
        waiter: KeyWaiter, prompts: Bool, timeout: Duration,
        isCurrent: () -> Bool,
        approve: () async -> Bool,
        fetch: () async -> Bool
    ) async -> Bool {
        let prompt = prompts ? waiter.promptStarted() : nil
        defer { if let prompt { waiter.promptEnded(prompt) } }
        guard await approve(), isCurrent() else { return false }
        if prompts { _ = await waiter.waitUntilKey(timeout: timeout) }
        guard isCurrent(), await fetch() else { return false }
        // Key now, not "back": once the wait has ended (back, or timed out), a resign that was late has had the
        // whole wait to arrive, so `isKey` is no longer stale. A prompt that never took the key is shown, as
        // approving promises (fix round 5).
        return isCurrent() && waiter.isKey
    }
}
