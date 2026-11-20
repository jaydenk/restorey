import Foundation

/// Notices promptly that an update replaced the agent's executable while this process keeps running the old one, so the
/// agent restarts by itself (`AgentState.restartForReplacedBinary`). `PlanRunner.isWindingDown` notices too, but only
/// before a restic step, so an idle agent would never restart. Meanwhile the app's connection refuses this process for its
/// signature, which seals an Info.plist no longer on disk (Task 7), and so the app can't ask it to restart either.
public enum ReplacementWatch {
    /// Often enough that an update's "Updating the background agent…" lasts seconds. Each check is one `stat`
    /// (`ExecutableFingerprint`).
    public static let interval: Duration = .seconds(5)

    /// Checks `replaced` now and then every `interval` until it is true, then calls `onReplaced` once and returns.
    /// Returns without calling it when cancelled.
    public static func run(
        every interval: Duration = interval, replaced: @Sendable () -> Bool, onReplaced: @Sendable () async -> Void
    ) async {
        while !Task.isCancelled {
            if replaced() {
                await onReplaced()
                return
            }
            try? await Task.sleep(for: interval)
        }
    }
}
