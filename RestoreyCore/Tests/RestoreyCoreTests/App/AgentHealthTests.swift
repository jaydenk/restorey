import Foundation
import Testing
@testable import RestoreyCore

struct AgentHealthTests {
    private static let prefix = "/Applications/RestoreyDev.app/Contents/Helpers/"

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func reply(
        version: String = "0.1.0", build: String = "7",
        path: String = prefix + "RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent", draining: Bool = false
    ) -> HelloReply {
        HelloReply(agentVersion: version, agentBuild: build, executablePath: path, draining: draining,
                   notificationsAuthorised: true)
    }

    /// A repair 30 minutes ago by this same build.
    private static let recentRepair = RepairRecord(at: now.addingTimeInterval(-1800), appVersion: "0.1.0", appBuild: "7")

    private static func input(
        _ smStatus: AgentServiceStatus = .enabled,
        heartbeat: AgentHeartbeat = .ok(reply()),
        storedPlistHash: String? = "abc",
        lastRepair: RepairRecord? = nil
    ) -> AgentHealthInput {
        AgentHealthInput(
            smStatus: smStatus, heartbeat: heartbeat, expectedExecutablePrefix: prefix, appVersion: "0.1.0",
            appBuild: "7", storedPlistHash: storedPlistHash, currentPlistHash: "abc", lastRepair: lastRepair,
            now: now)
    }

    private static func input(
        _ smStatus: AgentServiceStatus = .enabled,
        heartbeat: AgentHeartbeat = .ok(reply()),
        storedPlistHash: String? = "abc",
        repairAttemptedRecently: Bool
    ) -> AgentHealthInput {
        input(smStatus, heartbeat: heartbeat, storedPlistHash: storedPlistHash,
              lastRepair: repairAttemptedRecently ? recentRepair : nil)
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

    /// Ruling R51: the limit survives a relaunch. The record is persisted, so a relaunch of the same
    /// build within the hour doesn't repair again.
    @Test func relaunchWithinTheHourDoesNotRepair() {
        let elsewhere = Self.reply(path: "/Volumes/X/RestoreyDevAgent")
        let input = Self.input(heartbeat: .ok(elsewhere), lastRepair: Self.recentRepair)
        #expect(input.repairAttemptedRecently)
        #expect(decideAgentHealth(input) == .showNotRunning(canRepair: true))
    }

    /// A new build restarts the agent at once, whatever the last build did.
    @Test func newBuildIgnoresTheLastRepair() {
        let other = Self.reply(build: "6")
        for record in [
            RepairRecord(at: Self.recentRepair.at, appVersion: "0.1.0", appBuild: "6"),
            RepairRecord(at: Self.recentRepair.at, appVersion: "0.0.9", appBuild: "7"),
        ] {
            let input = Self.input(heartbeat: .ok(other), lastRepair: record)
            #expect(!input.repairAttemptedRecently)
            #expect(decideAgentHealth(input) == .restartAfterDrain)
        }
    }

    @Test func repairOverAnHourAgoAllowsAnother() {
        let old = RepairRecord(at: Self.now.addingTimeInterval(-3601), appVersion: "0.1.0", appBuild: "7")
        #expect(decideAgentHealth(Self.input(storedPlistHash: "old", lastRepair: old)) == .reregisterAfterDrain)
        // A clock that moved backwards doesn't block repairs for longer than an hour.
        let future = RepairRecord(at: Self.now.addingTimeInterval(600), appVersion: "0.1.0", appBuild: "7")
        #expect(!Self.input(lastRepair: future).repairAttemptedRecently)
    }

    @Test func repairRecordRoundTrips() throws {
        let data = try XPCCoding.encode(Self.recentRepair)
        #expect(try XPCCoding.decode(RepairRecord.self, from: data) == Self.recentRepair)
    }

    @Test func versionMismatchRestarts() {
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(version: "0.0.9")))) == .restartAfterDrain)
    }

    /// An agent already draining is about to exit (or is stuck drained): wait for it, don't start another
    /// repair, whatever its build.
    @Test func drainingAgentWaitsForUpdate() {
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(draining: true)))) == .waitForUpdate)
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(build: "6", draining: true)))) == .waitForUpdate)
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(draining: true)), repairAttemptedRecently: true))
            == .waitForUpdate)
    }

    @Test func repairIntervalIsAnHour() {
        #expect(AgentHealthPolicy.repairInterval == 3600)
        #expect(AgentHealthPolicy.heartbeatInterval == 10)
    }
}
