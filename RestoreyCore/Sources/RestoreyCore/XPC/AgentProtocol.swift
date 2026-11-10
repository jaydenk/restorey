import Foundation

/// The agent's XPC interface, served on the Mach service `Identity.agentLabel` to the app only (the
/// listener checks the caller's code signature).
///
/// Every reply is `(payload, error)`: exactly one is non-nil. The payload is JSON (`XPCCoding`), the
/// error a sentence in Australian English to show as is. Plan IDs are UUID strings.
///
/// Mutating calls (`savePlan`, `deletePlan`, `pause`, `resume`, `confirmRecoveryKit`, `backUpNow`,
/// `createRepository`) reply with the new `AgentStatus`. While a config error is reported, all of them
/// are refused. While draining, all of them and `adopt` are refused, except `pause`: the user can still
/// pause a long first backup, the run then ends paused, the drain completes and the next agent honours
/// `pausedUntil`.
@objc public protocol AgentXPC {
    /// `HelloRequest` → `HelloReply`.
    func hello(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `AgentStatus`.
    func status(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// `SavePlanRequest` → `AgentStatus`. The agent is the only writer of config and secrets.
    func savePlan(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Removes the plan, its secrets, credentials file and history. Never touches the repository.
    func deletePlan(_ id: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// One plan, or every plan when `planID` is nil.
    func backUpNow(_ planID: String?, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Pauses for an hour, then resumes on its own.
    func pause(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func resume(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Runs `restic init`: the only call that ever does.
    func createRepository(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `AdoptReport`.
    func adopt(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// The user says the recovery details are saved. A plan never runs on its own before this.
    func confirmRecoveryKit(_ planID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `NotificationPermissionReply`. Asks from the agent, which is what posts the notifications.
    func requestNotificationPermission(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    /// → `DrainReply` once no run is in flight. No timeout: a long first backup is waited for, and no
    /// new run starts meanwhile. The agent then exits and launchd starts the new binary.
    func prepareForRestart(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// What the app exports on its connection so the agent can push status. Pushed on every phase change,
/// and at most twice a second while a run reports progress.
@objc public protocol AgentClientXPC {
    /// `AgentStatus` JSON.
    func statusChanged(_ status: Data)
}
