import Foundation

/// Whether a window is the key window, fed by its key notifications (`becameKey`, `resignedKey`), with a wait for
/// it to become key. Restore Files and the kit window use it after a Touch ID or password prompt: the prompt takes
/// the key window, and the window that asked gets it back only once macOS grants Restorey's activation, which
/// happens asynchronously (fix round 3, N1).
@MainActor
public final class KeyWaiter {
    public private(set) var isKey = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init() {}

    public func becameKey() {
        isKey = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed.values { waiter.resume(returning: true) }
    }

    public func resignedKey() {
        isKey = false
    }

    /// True once the window is key (at once if it already is); false after `timeout` without it.
    public func waitUntilKey(timeout: Duration) async -> Bool {
        if isKey { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                self.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }
}

/// The order of a reveal after the owner approved it (fix round 3, N1): wait for the window to be key again (or
/// `timeout`), then fetch the secrets, then show them only if the window is still key. Fetching first would usually
/// finish before macOS gives the window back, and the approval would be lost; checking after the fetch keeps an
/// owner who switched away from finding the secrets shown when they come back.
@MainActor
public enum RevealOrder {
    /// Whether to show the secrets. `fetch` returns whether they arrived; it runs even if the window doesn't come
    /// back in time, since a copy needs them anyway.
    public static func afterApproval(
        waiter: KeyWaiter, timeout: Duration, fetch: () async -> Bool
    ) async -> Bool {
        _ = await waiter.waitUntilKey(timeout: timeout)
        guard await fetch() else { return false }
        return waiter.isKey
    }
}
