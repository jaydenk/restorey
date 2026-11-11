import Testing
@testable import AgentCore

/// Ruling R66: only the launchd job for the label runs the agent; XCTest's host stays idle; anything else
/// is refused. The environments are the ones observed on 11 Nov 2026.
struct AgentLaunchRoleTests {
    static let dev = "com.jaydenkerr.restorey.dev.agent"

    /// The real Debug agent, as `launchctl print gui/501/com.jaydenkerr.restorey.dev.agent` lists it, plus
    /// `XPC_FLAGS`, which the running agent also had.
    static let jobEnvironment = [
        "XPC_SERVICE_NAME": dev, "XPC_FLAGS": "1", "OSLogRateLimit": "64",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SSH_AUTH_SOCK": "/var/run/com.apple.launchd.x/Listeners",
    ]

    /// The agent bundle launched from DerivedData as XCTest's host by `xcodebuild test`.
    static let testHostEnvironment = [
        "XPC_SERVICE_NAME": "application.\(dev).1234.5678.0A1B2C3D-0000-4000-8000-000000000000",
        "XPC_FLAGS": "0x0", "XCTestConfigurationFilePath": "/var/folders/x/T/Restorey.xctestconfiguration",
        "XCTestSessionIdentifier": "6E8D1B3A-0000-4000-8000-000000000000", "PATH": "/usr/bin:/bin",
    ]

    @Test func theLaunchdJobRuns() {
        #expect(AgentLaunchRole.decide(environment: Self.jobEnvironment, label: Self.dev) == .launchdJob)
        // Only the label decides: launchd restarting the job after an update gives the same variable, and
        // the rest of the environment (a missing XPC_FLAGS, a different PATH) doesn't matter.
        #expect(AgentLaunchRole.decide(environment: ["XPC_SERVICE_NAME": Self.dev], label: Self.dev) == .launchdJob)
        // Even if XCTest variables leaked in, the job is still the job.
        var leaked = Self.jobEnvironment
        leaked["XCTestConfigurationFilePath"] = "/tmp/x"
        #expect(AgentLaunchRole.decide(environment: leaked, label: Self.dev) == .launchdJob)
    }

    @Test func theXCTestHostStaysIdle() {
        #expect(AgentLaunchRole.decide(environment: Self.testHostEnvironment, label: Self.dev) == .testHost)
        for variable in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(AgentLaunchRole.decide(environment: [variable: "x"], label: Self.dev) == .testHost)
        }
        #expect(AgentLaunchRole.decide(environment: ["XCTestBundlePath": ""], label: Self.dev) != .testHost)
    }

    @Test func everythingElseIsRefused() {
        let others: [[String: String]] = [
            ["XPC_SERVICE_NAME": "0"], // run from a shell
            [:], // nothing at all
            ["XPC_SERVICE_NAME": "application.\(Self.dev).1.2.UUID"], // double-clicked in Finder
            ["XPC_SERVICE_NAME": Self.dev + ".helper"], // a name that only starts with the label
            ["XPC_SERVICE_NAME": "com.jaydenkerr.restorey.agent"], // the other build's job
        ]
        for environment in others {
            guard case .refused(let reason) = AgentLaunchRole.decide(environment: environment, label: Self.dev) else {
                Issue.record("\(environment) should be refused")
                continue
            }
            #expect(reason.contains(Self.dev))
            #expect(reason.contains("XPC_SERVICE_NAME is \(environment["XPC_SERVICE_NAME"].map { "\"\($0)\"" } ?? "unset")"))
        }
        // The Debug job's environment doesn't run the Release agent.
        #expect(AgentLaunchRole.decide(environment: Self.jobEnvironment, label: "com.jaydenkerr.restorey.agent")
            != .launchdJob)
    }

    @Test func aRefusalExitsWithItsOwnStatus() {
        // Helper mode exits 0, 1 or 2.
        #expect(![0, 1, 2].contains(AgentLaunchRole.refusedExitStatus))
    }
}
