import Foundation
import Testing
@testable import RestoreyCore

struct AgentHealthTests {
    private static let prefix = "/Applications/RestoreyDev.app/Contents/Helpers/"

    private static func reply(
        build: String = "7", path: String = prefix + "RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent"
    ) -> HelloReply {
        HelloReply(agentVersion: "0.1.0", agentBuild: build, executablePath: path, draining: false,
                   notificationsAuthorised: true)
    }

    private static func input(
        _ smStatus: AgentServiceStatus = .enabled,
        heartbeat: AgentHeartbeat = .ok(reply()),
        storedPlistHash: String? = "abc",
        repairAttemptedRecently: Bool = false
    ) -> AgentHealthInput {
        AgentHealthInput(
            smStatus: smStatus, heartbeat: heartbeat, expectedExecutablePrefix: prefix, appBuild: "7",
            storedPlistHash: storedPlistHash, currentPlistHash: "abc",
            repairAttemptedRecently: repairAttemptedRecently)
    }

    @Test func healthyAgentNeedsNothing() {
        #expect(decideAgentHealth(Self.input()) == .none)
    }

    /// Spike H3a: `notFound` before the first `register()`, not `notRegistered`.
    @Test func notFoundRegisters() {
        #expect(decideAgentHealth(Self.input(.notFound, heartbeat: .unreachable)) == .register)
    }

    @Test func notRegisteredRegisters() {
        #expect(decideAgentHealth(Self.input(.notRegistered, heartbeat: .unreachable)) == .register)
        #expect(decideAgentHealth(Self.input(.notRegistered, repairAttemptedRecently: true)) == .register)
    }

    /// Spike phase B: a copy launched elsewhere re-points the registration.
    @Test func executableOutsideBundleReregisters() {
        let elsewhere = Self.reply(path: "/Volumes/Restorey/RestoreyDev.app/Contents/Helpers/RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent")
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(elsewhere))) == .reregisterAfterDrain)
    }

    /// A sibling bundle whose name starts with ours is still outside it.
    @Test func siblingBundleWithSamePrefixReregisters() {
        let sibling = Self.reply(path: "/Applications/RestoreyDev.app.old/Contents/Helpers/RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent")
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(sibling))) == .reregisterAfterDrain)
    }

    /// APFS is case-insensitive, and a path typed in a shell may differ in case from launchd's.
    @Test func executablePathComparesCaseInsensitively() {
        let upper = Self.reply(path: Self.prefix.uppercased() + "RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent")
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(upper))) == .none)
    }

    @Test func plistHashChangeReregisters() {
        #expect(decideAgentHealth(Self.input(storedPlistHash: "old")) == .reregisterAfterDrain)
    }

    /// Registered before the hash was recorded (or by hand): launchd's copy is unknown.
    @Test func missingStoredPlistHashReregisters() {
        #expect(decideAgentHealth(Self.input(storedPlistHash: nil)) == .reregisterAfterDrain)
    }

    @Test func buildMismatchRestarts() {
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(build: "6")))) == .restartAfterDrain)
    }

    /// Re-registering restarts the agent too, so it wins over a plain restart.
    @Test func reregisterWinsOverRestart() {
        let both = Self.reply(build: "6", path: "/Volumes/X/RestoreyDevAgent")
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(both))) == .reregisterAfterDrain)
    }

    /// Ruling R50: until the "switched off versus fault" check is done at the Mac, an enabled but
    /// unreachable agent is never repaired automatically.
    @Test func enabledUnreachableOffersRestartWithoutRepairing() {
        #expect(AgentHealthPolicy.enabledButUnreachable == .offerRestart)
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable)) == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, repairAttemptedRecently: true))
            == .showNotRunning(canRepair: true))
    }

    /// The row as the brief first wrote it, ready for when the check shows "switched off" reads
    /// `requiresApproval`: flipping `AgentHealthPolicy.enabledButUnreachable` turns it on.
    @Test func enabledUnreachableRepairsWhenPolicyAllows() {
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable), enabledButUnreachable: .repairAutomatically)
            == .reregisterAfterDrain)
        #expect(decideAgentHealth(
            Self.input(heartbeat: .unreachable, repairAttemptedRecently: true), enabledButUnreachable: .repairAutomatically)
            == .showNotRunning(canRepair: true))
    }

    /// The user switched it off in Login Items: never re-enabled behind their back.
    @Test func requiresApprovalShowsSwitchedOff() {
        #expect(decideAgentHealth(Self.input(.requiresApproval, heartbeat: .unreachable)) == .showSwitchedOff)
        #expect(decideAgentHealth(Self.input(.requiresApproval, storedPlistHash: "old")) == .showSwitchedOff)
    }

    /// At most one automatic repair an hour: a fault that survives one shows a "Restart agent" button
    /// instead of draining and restarting the agent every heartbeat.
    @Test func repairRateLimited() {
        let elsewhere = Self.reply(path: "/Volumes/X/RestoreyDevAgent")
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(elsewhere), repairAttemptedRecently: true))
            == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(storedPlistHash: "old", repairAttemptedRecently: true))
            == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(build: "6")), repairAttemptedRecently: true))
            == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(repairAttemptedRecently: true)) == .none)
    }

    @Test func repairIntervalIsAnHour() {
        #expect(AgentHealthPolicy.repairInterval == 3600)
        #expect(AgentHealthPolicy.heartbeatInterval == 10)
    }
}
