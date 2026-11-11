import Foundation

/// What the agent executable is in this process, decided before it touches any of its identity's files
/// (Ruling R66). The agent assumes it is the only instance; only the launchd job for its label may run its
/// start-up, or a second copy (an XCTest host, a double-click in Finder) would log into the real
/// `agent.log`, load the real `config.json` and `state.json`, run recovery and a scheduler, and write
/// beside the real agent.
///
/// The job is recognised by `XPC_SERVICE_NAME`: launchd sets it to the job's label in the environment
/// of every process it starts for a job (seen in `launchctl print gui/<uid>/<label>` under
/// `environment`, and in a throwaway `launchctl submit` job, 11 Nov 2026). Other processes inherit a
/// different value: `0` from a login shell, `application.<bundle id>.<n>.<n>.<uuid>` for an app that
/// LaunchServices started, the XCTest host included. Asking launchd itself (`bootstrap_check_in` on the
/// Mach service) would take the receive right `NSXPCListener` checks in for later, and a refused
/// `NSXPCListener` registration is only logged by launchd, never reported to the process, so the
/// environment is the check that can run first.
public enum AgentLaunchRole: Equatable, Sendable {
    /// The launchd job: run the agent.
    case launchdJob
    /// XCTest's host process: do nothing to the identity and let XCTest run its bundle.
    case testHost
    /// Anything else: refuse, with the reason for the unified log.
    case refused(reason: String)

    /// Exit status of a refused start-up, distinct from helper mode's 1 and 2 (`EX_CONFIG`).
    public static let refusedExitStatus: Int32 = 78

    /// The variables XCTest sets in the host process it injects a test bundle into.
    static let xcTestVariables = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    public static func decide(environment: [String: String], label: String) -> AgentLaunchRole {
        let service = environment["XPC_SERVICE_NAME"]
        if service == label { return .launchdJob }
        if xcTestVariables.contains(where: { !(environment[$0] ?? "").isEmpty }) { return .testHost }
        return .refused(reason:
            "not started by launchd as the \(label) job (XPC_SERVICE_NAME is \(service.map { "\"\($0)\"" } ?? "unset")); "
            + "only one agent may run, and launchd starts it")
    }
}
