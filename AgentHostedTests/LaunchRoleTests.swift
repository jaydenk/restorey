import AgentCore
import Foundation
import Testing
import RestoreyCore

/// Ruling R66, from inside the host itself: this process is XCTest's host, not the launchd job, so the
/// agent's `main` took the test-host branch and ran none of its start-up (no agent.log line, no config or
/// state, no listeners, recovery or scheduler).
@Suite struct LaunchRoleTests {
    @Test func thisHostIsTheTestHostNotTheJob() throws {
        let identity = try Identity.fromBundle(.main)
        let environment = ProcessInfo.processInfo.environment
        #expect(environment["XPC_SERVICE_NAME"] != identity.agentLabel)
        #expect(AgentLaunchRole.decide(environment: environment, label: identity.agentLabel) == .testHost)
    }
}
