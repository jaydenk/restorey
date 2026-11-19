import AppKit
import RestoreyCore

/// The agent calls behind the menu's Back Up Now, Pause and Resume, shared by the menu and Settings' Overview tab
/// (Task 14c) so both ask the same way and show the same alert when one fails.
@MainActor
enum AgentActions {
    static let backUpFailed = "Restorey couldn’t start the backup"
    static let pauseFailed = "Restorey couldn’t pause the backup"
    static let cancelFailed = "Restorey couldn’t cancel the backup"
    static let resumeFailed = "Restorey couldn’t resume the backup"

    /// `planID` nil: every plan (the menu's "All Plans").
    static func backUpNow(_ planID: UUID?, _ connection: AgentConnection) {
        run(backUpFailed) { [await connection.backUpNow(planID).map(\.status)] }
    }

    static func pause(_ plans: [UUID], for length: PauseLength, _ connection: AgentConnection) {
        run(pauseFailed) { await each(plans) { await connection.pause($0, for: length) } }
    }

    static func cancel(_ plans: [UUID], _ connection: AgentConnection) {
        run(cancelFailed) { await each(plans, connection.cancel) }
    }

    static func resume(_ plans: [UUID], _ connection: AgentConnection) {
        run(resumeFailed) { await each(plans, connection.resume) }
    }

    private static func each(
        _ plans: [UUID], _ call: (UUID) async -> Result<AgentStatus, AgentCallError>
    ) async -> [Result<AgentStatus, AgentCallError>] {
        var results: [Result<AgentStatus, AgentCallError>] = []
        for plan in plans { results.append(await call(plan)) }
        return results
    }

    /// Runs the calls; the first failure is shown in an alert. Each reply is a status, which the connection hands
    /// to the supervisor, so the menu and Settings show the change.
    static func run(_ failureTitle: String, _ calls: @escaping @MainActor () async -> [Result<AgentStatus, AgentCallError>]) {
        Task {
            for result in await calls() {
                guard case .failure(let error) = result else { continue }
                let alert = NSAlert()
                alert.messageText = failureTitle
                alert.informativeText = error.description
                WindowActivation.runModal(alert)
                return
            }
        }
    }
}
