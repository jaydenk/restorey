import Foundation
import Testing
@testable import RestoreyCore

struct AgentHealthTests {
    private static let prefix = "/Applications/RestoreyDev.app/Contents/Helpers/"

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func reply(
        version: String = "0.1.0", build: String = "7",
        path: String = prefix + "RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent", draining: Bool = false,
        fingerprint: String? = "disk"
    ) -> HelloReply {
        HelloReply(agentVersion: version, agentBuild: build, executablePath: path, draining: draining,
                   notificationsAuthorised: true, executableFingerprint: fingerprint)
    }

    /// A repair 30 minutes ago by this same build.
    private static func recent(_ kind: RepairKind) -> RepairRecord {
        RepairRecord(kind: kind, at: now.addingTimeInterval(-1800), appVersion: "0.1.0", appBuild: "7")
    }
    private static let recentRepair = recent(.reregister)

    private static func input(
        _ smStatus: AgentServiceStatus = .enabled,
        heartbeat: AgentHeartbeat = .ok(reply()),
        storedPlistHash: String? = "abc",
        lastRepairs: [RepairRecord] = [],
        unreachableFor: TimeInterval? = nil
    ) -> AgentHealthInput {
        AgentHealthInput(
            smStatus: smStatus, heartbeat: heartbeat, expectedExecutablePrefix: prefix, appVersion: "0.1.0",
            appBuild: "7", storedPlistHash: storedPlistHash, currentPlistHash: "abc",
            executableFingerprintOnDisk: "disk", lastRepairs: lastRepairs,
            unreachableSince: unreachableFor.map { now.addingTimeInterval(-$0) }, now: now)
    }

    private static func input(
        _ smStatus: AgentServiceStatus = .enabled,
        heartbeat: AgentHeartbeat = .ok(reply()),
        storedPlistHash: String? = "abc",
        repairAttemptedRecently: Bool,
        unreachableFor: TimeInterval? = nil
    ) -> AgentHealthInput {
        input(smStatus, heartbeat: heartbeat, storedPlistHash: storedPlistHash,
              lastRepairs: repairAttemptedRecently ? [recent(.restart), recent(.reregister)] : [],
              unreachableFor: unreachableFor)
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

    /// Fix round 3: a stale agent (an older binary of the same version and build) may not know newer
    /// calls such as `prepareForReregistration`, so it is restarted first with `prepareForRestart`, which
    /// every agent has. The fresh agent then re-registers.
    @Test func restartComesBeforePlistReregistration() {
        let stale = Self.reply(fingerprint: nil)
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(stale), storedPlistHash: nil)) == .restartAfterDrain)
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(build: "6")), storedPlistHash: "old"))
            == .restartAfterDrain)
    }

    /// A re-pointed registration is never restarted: launchd would relaunch the copy elsewhere (spike
    /// phase B). It re-registers whatever else differs.
    @Test func executableOutsideBundleWinsOverRestart() {
        let both = Self.reply(build: "6", path: "/Volumes/X/RestoreyDevAgent", fingerprint: nil)
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(both))) == .reregisterAfterDrain)
    }

    /// The live case: the agent kept running a replaced binary with the same version and build.
    @Test func replacedBinaryRestarts() {
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(fingerprint: "before-install"))))
            == .restartAfterDrain)
    }

    /// An agent from before fingerprints existed reports none, which counts as replaced.
    @Test func agentWithoutFingerprintRestarts() {
        #expect(decideAgentHealth(Self.input(heartbeat: .ok(Self.reply(fingerprint: nil)))) == .restartAfterDrain)
    }

    @Test func agentIsCurrentNeedsVersionBuildAndBinary() {
        let disk = "disk"
        #expect(agentIsCurrent(Self.reply(), appVersion: "0.1.0", appBuild: "7", executableFingerprintOnDisk: disk))
        #expect(!agentIsCurrent(Self.reply(version: "0.0.9"), appVersion: "0.1.0", appBuild: "7", executableFingerprintOnDisk: disk))
        #expect(!agentIsCurrent(Self.reply(build: "6"), appVersion: "0.1.0", appBuild: "7", executableFingerprintOnDisk: disk))
        #expect(!agentIsCurrent(Self.reply(fingerprint: "old"), appVersion: "0.1.0", appBuild: "7", executableFingerprintOnDisk: disk))
        #expect(!agentIsCurrent(Self.reply(fingerprint: nil), appVersion: "0.1.0", appBuild: "7", executableFingerprintOnDisk: disk))
        // The app can't read the file: it can't confirm the agent is current.
        #expect(!agentIsCurrent(Self.reply(), appVersion: "0.1.0", appBuild: "7", executableFingerprintOnDisk: nil))
    }

    /// Fix round 3, item 3: with nothing recorded, launchd's job definition is unknown, so it is
    /// re-registered once rather than trusted (see the report).
    @Test func plistRule() {
        #expect(!plistNeedsReregistration(stored: "abc", current: "abc"))
        #expect(plistNeedsReregistration(stored: "old", current: "abc"))
        #expect(plistNeedsReregistration(stored: nil, current: "abc"))
    }

    /// Ruling R54 (the spec §6.2 check): switched off reads `requiresApproval`, so an `enabled` agent
    /// that doesn't answer is a fault and is repaired automatically, but only once it has been
    /// unreachable for `unreachableGrace`: `unregister()` kills a running restic, and one missed
    /// heartbeat (a busy or briefly stopped agent) is not a fault.
    @Test func enabledUnreachableRepairsAfterTheGrace() {
        #expect(AgentHealthPolicy.enabledButUnreachable == .repairAutomatically)
        #expect(AgentHealthPolicy.unreachableGrace == 30)
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable)) == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, unreachableFor: 0))
            == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, unreachableFor: 29.9))
            == .showNotRunning(canRepair: true))
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, unreachableFor: 30)) == .reregisterAfterDrain)
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, unreachableFor: 600)) == .reregisterAfterDrain)
    }

    /// Ruling R68: an unreachable agent can't be drained, so while a restic it started is running the app
    /// waits rather than unregister it, and decides again at the next heartbeat.
    @Test func anUnreachableAgentRunningResticIsNotUnregistered() {
        func decide(running: Bool, for seconds: TimeInterval?) -> AgentHealthAction {
            var input = Self.input(heartbeat: .unreachable, unreachableFor: seconds)
            input.resticRunningUnderAgent = running
            return decideAgentHealth(input)
        }
        #expect(decide(running: true, for: 600) == .waitForRunningRestic)
        #expect(decide(running: true, for: 10) == .showNotRunning(canRepair: true), "inside the grace, as before")
        // The backup has finished: the next heartbeat repairs.
        #expect(decide(running: false, for: 610) == .reregisterAfterDrain)
        // A reachable agent is drained, so a running restic changes nothing there.
        var reachable = Self.input(heartbeat: .ok(Self.reply(path: "/elsewhere/RestoreyDevAgent")))
        reachable.resticRunningUnderAgent = true
        #expect(decideAgentHealth(reachable) == .reregisterAfterDrain)
    }

    /// A fault that survives one repair waits for the user ("Restart Agent").
    @Test func enabledUnreachableRepairsAtMostHourly() {
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, repairAttemptedRecently: true, unreachableFor: 600))
            == .showNotRunning(canRepair: true))
    }

    /// The conservative row is still there if a later macOS changes what "switched off" reads.
    @Test func enabledUnreachableOffersRestartWhenPolicyIsConservative() {
        #expect(decideAgentHealth(Self.input(heartbeat: .unreachable, unreachableFor: 600), enabledButUnreachable: .offerRestart)
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
        let input = Self.input(heartbeat: .ok(elsewhere), lastRepairs: [Self.recentRepair])
        #expect(input.repairAttemptedRecently(.reregister))
        #expect(decideAgentHealth(input) == .showNotRunning(canRepair: true))
    }

    /// A new build restarts the agent at once, whatever the last build did.
    @Test func newBuildIgnoresTheLastRepair() {
        let other = Self.reply(build: "6")
        for record in [
            RepairRecord(kind: .restart, at: Self.recentRepair.at, appVersion: "0.1.0", appBuild: "6"),
            RepairRecord(kind: .restart, at: Self.recentRepair.at, appVersion: "0.0.9", appBuild: "7"),
        ] {
            let input = Self.input(heartbeat: .ok(other), lastRepairs: [record])
            #expect(!input.repairAttemptedRecently(.restart))
            #expect(decideAgentHealth(input) == .restartAfterDrain)
        }
    }

    @Test func repairOverAnHourAgoAllowsAnother() {
        let old = RepairRecord(kind: .reregister, at: Self.now.addingTimeInterval(-3601), appVersion: "0.1.0", appBuild: "7")
        #expect(decideAgentHealth(Self.input(storedPlistHash: "old", lastRepairs: [old])) == .reregisterAfterDrain)
        // A clock that moved backwards doesn't block repairs for longer than an hour.
        let future = RepairRecord(kind: .reregister, at: Self.now.addingTimeInterval(600), appVersion: "0.1.0", appBuild: "7")
        #expect(!Self.input(lastRepairs: [future]).repairAttemptedRecently(.reregister))
    }

    /// Fix round 3: the limit is per kind. A stale agent is restarted, and the fresh agent must then be
    /// re-registered for a changed plist straight away, not an hour later.
    @Test func restartThenReregistrationAreBothAllowed() {
        let afterRestart = Self.input(storedPlistHash: nil, lastRepairs: [Self.recent(.restart)])
        #expect(decideAgentHealth(afterRestart) == .reregisterAfterDrain)
        let afterReregister = Self.input(heartbeat: .ok(Self.reply(fingerprint: nil)), lastRepairs: [Self.recent(.reregister)])
        #expect(decideAgentHealth(afterReregister) == .restartAfterDrain)
        // A repeat of the same kind within the hour waits for the user.
        let again = Self.input(heartbeat: .ok(Self.reply(fingerprint: nil)), lastRepairs: [Self.recent(.restart)])
        #expect(decideAgentHealth(again) == .showNotRunning(canRepair: true))
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

    // MARK: Switched off mid-session

    /// `SMAppService.status` is read at every heartbeat, so switching the agent off in Login Items while the
    /// app runs shows at the next one, and switching it back on recovers at the next one after that.
    @Test func switchingOffMidSessionShowsAtTheNextHeartbeat() {
        let beats: [(AgentServiceStatus, AgentHeartbeat, AgentHealthAction)] = [
            (.enabled, .ok(Self.reply()), .none),
            (.requiresApproval, .unreachable, .showSwitchedOff),
            // launchd removed the job, but a hello may still be answered on the way out: still switched off.
            (.requiresApproval, .ok(Self.reply()), .showSwitchedOff),
            (.enabled, .ok(Self.reply()), .none),
        ]
        for (index, (smStatus, beat, expected)) in beats.enumerated() {
            #expect(decideAgentHealth(Self.input(smStatus, heartbeat: beat)) == expected, "heartbeat \(index)")
        }
    }

    // MARK: Retired agent runs (R76)

    private static let runA = UUID()
    private static let runB = UUID()

    private static func status(run: UUID?, sequence: UInt64?, at seconds: TimeInterval = 0) -> AgentStatus {
        AgentStatus(
            plans: [], configError: nil, fdaMissing: false, generatedAt: now.addingTimeInterval(seconds),
            agentRun: run, sequence: sequence)
    }

    @Test func aStatusFromARetiredRunIsDropped() {
        let current = Self.status(run: Self.runB, sequence: 1)
        let late = Self.status(run: Self.runA, sequence: 90)
        #expect(!shouldAccept(status: late, current: current, retired: [Self.runA]))
        // With nothing shown yet, a retired run is still dropped.
        #expect(!shouldAccept(status: late, current: nil, retired: [Self.runA]))
    }

    @Test func otherwiseOrderingIsBySupersedes() {
        let shown = Self.status(run: Self.runA, sequence: 5)
        #expect(shouldAccept(status: Self.status(run: Self.runA, sequence: 6), current: shown, retired: []))
        #expect(!shouldAccept(status: Self.status(run: Self.runA, sequence: 4), current: shown, retired: []))
        #expect(shouldAccept(status: Self.status(run: Self.runB, sequence: 1), current: shown, retired: [Self.runC]))
        // An agent older than run IDs is ordered by time, and never counted as retired.
        let old = Self.status(run: nil, sequence: nil, at: 10)
        #expect(shouldAccept(status: old, current: Self.status(run: nil, sequence: nil), retired: [Self.runA]))
    }

    private static let runC = UUID()

    /// A hello naming a new run retires the one before it, so a late reply from the old process can't
    /// replace the new agent's status.
    @Test func aHelloFromANewRunRetiresTheOldOne() {
        var tracker = AgentRunTracker()
        tracker.helloReported(Self.runA)
        #expect(tracker.current == Self.runA)
        #expect(tracker.retired.isEmpty)
        tracker.helloReported(Self.runA)
        #expect(tracker.retired.isEmpty, "the same run again changes nothing")
        tracker.helloReported(Self.runB)
        #expect(tracker.current == Self.runB)
        #expect(tracker.retired == [Self.runA])
        let shown = Self.status(run: Self.runB, sequence: 1)
        #expect(!tracker.shouldAccept(Self.status(run: Self.runA, sequence: 99), over: shown))
        #expect(tracker.shouldAccept(Self.status(run: Self.runB, sequence: 2), over: shown))
    }

    /// Fix round 1: only hellos retire runs, since heartbeats are serialised and their order is reliable. A late
    /// status from a run the app never saw must not retire the live one: that froze the menu until relaunch.
    @Test func aStatusNeverRetiresARun() {
        var tracker = AgentRunTracker()
        tracker.helloReported(Self.runB)
        let fromB = Self.status(run: Self.runB, sequence: 1)
        tracker.statusAccepted(fromB.agentRun)
        // A late status from an earlier process (A) the app never heard a hello from: shown, as `supersedes` allows.
        let lateA = Self.status(run: Self.runA, sequence: 40)
        #expect(tracker.shouldAccept(lateA, over: fromB))
        tracker.statusAccepted(lateA.agentRun)
        #expect(tracker.current == Self.runB)
        #expect(tracker.retired.isEmpty)
        // B's next status still gets through, and B's next hello retires nothing (B is current).
        #expect(tracker.shouldAccept(Self.status(run: Self.runB, sequence: 2), over: lateA))
        tracker.helloReported(Self.runB)
        #expect(tracker.retired.isEmpty)
    }

    /// Before any hello, the first status names the current run, so the next hello from another run retires it.
    @Test func aStatusSetsTheCurrentRunOnlyWhenThereIsNone() {
        var tracker = AgentRunTracker()
        tracker.statusAccepted(Self.runA)
        #expect(tracker.current == Self.runA)
        tracker.statusAccepted(Self.runB)
        #expect(tracker.current == Self.runA)
        #expect(tracker.retired.isEmpty)
        tracker.helloReported(Self.runB)
        #expect(tracker.retired == [Self.runA])
        #expect(!tracker.shouldAccept(Self.status(run: Self.runA, sequence: 9), over: nil))
    }

    /// A retired run never becomes current again, and an agent without run IDs leaves the tracker alone.
    @Test func aRetiredRunNeverComesBack() {
        var tracker = AgentRunTracker()
        tracker.helloReported(Self.runA)
        tracker.helloReported(Self.runB)
        tracker.helloReported(Self.runA)
        #expect(tracker.current == Self.runB)
        #expect(tracker.retired == [Self.runA])
        tracker.helloReported(nil)
        tracker.statusAccepted(nil)
        #expect(tracker.current == Self.runB)
    }

    // MARK: Which status the menu shows

    /// While healthy only a status fetched since the return to healthy is shown. Otherwise the last one
    /// received stands in, so "Last known: …" and R68's "(agent not answering)" have something to show.
    @Test func theMenuShowsTheLastKnownStatusOnlyWhileUnhealthy() {
        let live = Self.status(run: Self.runB, sequence: 2)
        let last = Self.status(run: Self.runB, sequence: 1)
        #expect(menuStatus(health: .healthy, live: live, lastKnown: last) == live)
        #expect(menuStatus(health: .healthy, live: nil, lastKnown: last) == nil)
        for health: AgentHealthState in [.notRunning(reachable: false), .switchedOff, .updating, .checking] {
            #expect(menuStatus(health: health, live: nil, lastKnown: last) == last, "\(health)")
            #expect(menuStatus(health: health, live: live, lastKnown: last) == live, "\(health)")
        }
    }
}
