import Synchronization

/// Keeps the Mac from idle-sleeping while any restic run is in progress (spec §8). Runs are counted, so
/// two plans running at once share one assertion, taken when the first starts and released when the last
/// ends. Display sleep and lid-closed sleep are not prevented; the catch-up after waking covers those.
///
/// Every `begin()` must be paired with an `end()`, normally in a `defer`. An `end()` with nothing
/// begun is ignored.
public final class SleepPrevention: Sendable {
    /// The power assertion calls, injected so the counting is tested without IOKit. The agent passes
    /// `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` and `IOPMAssertionRelease`.
    public struct AssertionAPI: Sendable {
        /// Takes an assertion with this name; nil when it couldn't be taken.
        public var create: @Sendable (_ name: String) -> UInt32?
        public var release: @Sendable (_ id: UInt32) -> Void

        public init(
            create: @escaping @Sendable (_ name: String) -> UInt32?,
            release: @escaping @Sendable (_ id: UInt32) -> Void
        ) {
            self.create = create
            self.release = release
        }
    }

    /// The name macOS shows for the assertion (`pmset -g assertions`).
    public static let assertionName = "Restorey backup"

    private struct State {
        var count = 0
        var assertion: UInt32?
    }

    private let api: AssertionAPI
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    public init(api: AssertionAPI, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.api = api
        self.log = log
    }

    /// True while an assertion is held.
    public var isHeld: Bool { state.withLock { $0.assertion != nil } }

    /// A run has started: the first takes the assertion. If it can't be taken the run goes ahead
    /// anyway (a backup matters more than staying awake), and the next first run tries again.
    public func begin() {
        let failed = state.withLock { state -> Bool in
            state.count += 1
            guard state.count == 1 else { return false }
            state.assertion = api.create(Self.assertionName)
            return state.assertion == nil
        }
        if failed { log("Couldn't stop the Mac idle-sleeping during the backup, so a long run may stall if it sleeps") }
    }

    /// A run has ended: the last releases the assertion.
    public func end() {
        state.withLock { state in
            guard state.count > 0 else { return }
            state.count -= 1
            guard state.count == 0, let assertion = state.assertion else { return }
            state.assertion = nil
            api.release(assertion)
        }
    }
}
