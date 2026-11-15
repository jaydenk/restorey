import Foundation

/// The agent's XPC interface, served on the Mach service `Identity.agentLabel` to the app only (the
/// listener checks the caller's code signature).
///
/// Every reply is `(payload, error)`: exactly one is non-nil. The payload is JSON (`XPCCoding`), the
/// error a sentence in Australian English to show as is. Plan IDs are UUID strings.
///
/// Mutating calls (`savePlan`, `deletePlan`, `pause`, `resume`, `confirmRecoveryKit`, `backUpNow`,
/// `createRepository`, `saveNetworkSettings`, `dismissOffMacNote`, `removeEarlierSnapshotsAfterNextBackup`) reply with
/// the new `AgentStatus`. While a config error is reported, all of them are refused, and so are `history`, `recoveryKit`
/// and the earlier-snapshots calls. While draining, all of them, `adopt`, `probeRepository` and the earlier-snapshots
/// calls are refused, except `pause`: the user can still pause a long first backup,
/// the run then ends paused, the drain completes and the next agent honours `pausedUntil`.
///
/// Only `recoveryKit` replies with secrets, and only to this connection, which the listener accepts from
/// the signed app alone. The agent never logs that reply.
@objc public protocol AgentXPC {
    /// `HelloRequest` → `HelloReply`.
    func hello(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `AgentStatus`.
    func status(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `SavePlanRequest` → `AgentStatus`. The agent is the only writer of config and secrets.
    /// `plan.hasCheckInURL == false` deletes any stored check-in URL, so callers carry it over from the
    /// stored plan like any other field and set it false only when the user removes the URL.
    func savePlan(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `NetworkSettings` → `AgentStatus`. The Mac-wide network rules, saved with Wi-Fi names trimmed; settings
    /// with a problem (`NetworkSettings.validationErrors`) are refused with every reason.
    func saveNetworkSettings(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Removes the plan, its secrets, credentials file and history. Never touches the repository.
    func deletePlan(_ id: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// One plan, or every plan when `planID` is nil.
    func backUpNow(_ planID: String?, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Pauses for an hour, then resumes on its own.
    func pause(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Clears the pause and, if the plan was paused and isn't stopped, starts a backup at once as Back Up
    /// Now does (Ruling R59); its refusals come back as the error.
    func resume(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Runs `restic init`: the only call that ever does.
    func createRepository(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `AdoptReport`.
    func adopt(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `RepositoryProbe`: what is at the plan's repository address (`restic cat config`, then the adopt
    /// listing if a repository is there). Changes nothing. Setup calls it after saving the plan.
    func probeRepository(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `CredentialProbeRequest` → `RepositoryProbe`: what `probeRepository` would find with these credentials in place
    /// of the keychain's, which are left as they are. A check, not a run: nothing is saved or recorded.
    func probeRepositoryCredentials(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `EarlierSnapshotsPreview` (Task 14b): what the plan's retention would remove from its earlier snapshots (from
    /// before an adoption, and of previous folder lists). A `forget --dry-run` that takes no lock: nothing is removed
    /// and nothing is recorded.
    func previewEarlierSnapshots(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `EarlierSnapshotsRequest` → `EarlierSnapshotsRemoval` (Task 14b): removes the confirmed snapshots a fresh preview
    /// still puts in the confirmation's action, and nothing else. Recorded in History. Waits its turn in the repository's
    /// queue and for another client's lock (`--retry-lock`), so it can take minutes.
    func removeEarlierSnapshots(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `EarlierSnapshotsRequest` → `AgentStatus` (Task 14b): setup's confirmed removal, kept with the plan and run after
    /// its next backup that saves the data.
    func removeEarlierSnapshotsAfterNextBackup(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `[RunRecord]`, newest first: one plan's records, or every plan's when `planID` is nil.
    func history(_ planID: String?, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `RecoveryKitSecrets`: the plan and every secret stored for it, for the recovery kit. The only call
    /// that returns secrets.
    func recoveryKit(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `AgentStatus`, after running the agent's Full Disk Access probe; the status is also pushed.
    func probeFullDiskAccess(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `AgentStatus`. Hides the plan's "No off-Mac monitoring" note for good (`offMacNoteDismissed`).
    func dismissOffMacNote(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// The user says the recovery details are saved. A plan never runs on its own before this.
    func confirmRecoveryKit(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `NotificationPermissionReply`. Asks from the agent, which is what posts the notifications.
    func requestNotificationPermission(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `LocationPermissionReply` once the user has answered. Asks from the agent, which is what reads the
    /// Wi-Fi name: macOS reveals it only to a process with Location Services authorisation.
    func requestLocationPermission(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `DrainReply` once no run is in flight. No timeout: a long first backup is waited for, and no
    /// new run starts meanwhile. The agent then exits and launchd starts the new binary.
    func prepareForRestart(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `DrainReply`, like `prepareForRestart`, but the agent does not exit: it stays up, drained and
    /// refusing every mutating call but `pause`, so the app's `unregister()` stops this drained process
    /// rather than a fresh one launchd's `KeepAlive` started. Used before `unregister()` then `register()`.
    func prepareForReregistration(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// What the app exports on its connection so the agent can push status. Pushed on every phase change,
/// and at most twice a second while a run reports progress.
@objc public protocol AgentClientXPC {
    /// `AgentStatus` JSON.
    func statusChanged(_ status: Data)
}
