import AgentCore
import AppKit
import Foundation
import MetricKit
import OSLog
import RestoreyCore

// The agent is started by launchd from the LaunchAgent plist embedded in the app bundle.
// A real NSApplication run loop gives it a full app identity for UserNotifications.

// restic runs this same executable as its password command and S3 credential_process. That mode asks
// the running agent over XPC and exits: it must branch before NSApplication and before any listener.
if let code = HelperMode.exitCode(arguments: CommandLine.arguments) { exit(code) }

/// The binary this process was started from, recorded now: an install can replace the file while this
/// process keeps running the old one, and `hello` lets the app tell (fix round 3).
let launchFingerprint = Bundle.main.executableURL.flatMap(ExecutableFingerprint.of)

/// Objects that must live as long as the process: the XPC listener and its delegate (the listener
/// holds its delegate weakly), and the MetricKit subscriber.
var keptAlive: [AnyObject] = []

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

do {
    let identity = try Identity.fromBundle(.main)
    let log = AppLog(identity: identity, kind: .agent)
    log.info("Agent started, label \(identity.agentLabel), pid \(getpid())")

    let diagnostics = Diagnostics(
        directory: identity.logsDirectory().appendingPathComponent("diagnostics", isDirectory: true), log: log)
    MXMetricManager.shared.add(diagnostics)
    keptAlive.append(diagnostics)

    if let team = AgentListener.teamID(in: .main) {
        // Started now, so the network path is known by the first run.
        let observers = SystemObservers()
        keptAlive.append(observers)
        let scheduler = Scheduler(log: log)
        Task { @MainActor in
            let secrets = KeychainSecretStore(service: identity.rootID, accessGroup: identity.keychainAccessGroup)
            let state = await AgentState(
                directory: identity.applicationSupportDirectory(), secrets: secrets, now: { Date() })
            if let configError = await state.status().configError {
                log.error("Not running any plan until the settings are fixed: \(configError)")
            }
            let notifier = Notifier()
            await state.attach(notifier: notifier, log: { log.info($0) })
            let service = AgentService(
                state: state, log: log, notifier: notifier, executableFingerprint: launchFingerprint,
                plansChanged: { scheduler.nudge(.configChanged) }
            ) {
                // Give the reply time to leave before exiting; launchd's KeepAlive starts the new binary.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
            let listener = AgentListener(service: service, log: log)
            await state.setStatusObserver { listener.broadcast($0) }
            keptAlive.append(listener)
            keptAlive.append(listener.listen(identity: identity, team: team))

            let helper = HelperListener(
                responder: HelperResponder(
                    state: state, secrets: secrets, supervised: .shared, now: { Date() }),
                log: log)
            keptAlive.append(helper)
            keptAlive.append(helper.listen(identity: identity, team: team))

            // restic runs this executable for the password and S3 keys, so it must be the real path.
            // Without one, fail closed: no runner, and the app's run actions say the agent isn't ready.
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
                log.error("The agent can't find its own executable, so it won't run any backup")
                return
            }
            let runner = PlanRunner(dependencies: RunnerDependencies(
                state: state, secrets: secrets, queues: RepositoryQueues(), supervisor: .shared,
                logStore: RunLogStore(identity: identity),
                checkIn: CheckInService(
                    secrets: secrets, session: CheckInService.makeSession(),
                    log: { line, level in level == .error ? log.error(line) : log.info(line) },
                    onResult: { planID, status in await state.checkInResult(planID: planID, status: status) }),
                // <app>/Contents/Helpers/restic, beside this agent's own bundle.
                resticExecutable: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("restic"),
                helperExecutable: executable,
                cacheDirectory: identity.cachesDirectory().appendingPathComponent("restic", isDirectory: true),
                credentialsDirectory: identity.applicationSupportDirectory(),
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                logSubsystem: identity.rootID,
                fdaProbe: { FullDiskAccessProbe.probe() },
                preflightEnvironment: { observers.preflightEnvironment() },
                now: { Date() },
                sleepPrevention: SleepPrevention(api: SystemObservers.sleepAssertions) { log.error($0) },
                agentLog: { log.error($0) }))
            keptAlive.append(runner)
            // Recovery runs to completion before the runner is attached, so a run action that arrives
            // meanwhile is refused as "still starting up" rather than racing recovery. It runs after the
            // helper listener is up, because the unlock asks it for the repository password.
            await runner.recoverAfterStart()
            await state.attach(runner: runner)
            log.info("Recovery finished; the runner is accepting runs")

            // Only now, so no scheduled run races recovery (the scheduler's own recoverAfterStart() call
            // returns at once). A drain asked for during recovery means the agent is about to exit.
            guard !(await state.isDraining) else {
                log.info("Not starting the scheduler: the agent is finishing up before a restart")
                return
            }
            scheduler.start(runner: runner, observers: observers)
            let workspace = WorkspaceObserver()
            workspace.start(
                onWake: { scheduler.nudge(.wake) },
                onMount: { scheduler.nudge(.volumeMounted($0)) })
            keptAlive.append(workspace)
        }
    } else {
        // Exiting would make launchd's KeepAlive respawn the agent in a loop. Stay up, unreachable,
        // and let the app's heartbeat report it.
        log.error("RestoreyTeamID is missing or malformed in Info.plist; not starting the XPC listener")
    }
} catch {
    // No identity means no root ID for the log subsystem, so use the bundle identifier. As above,
    // never exit: log once and idle with no listener.
    Logger(subsystem: Bundle.main.bundleIdentifier ?? "Restorey", category: "agent")
        .fault("Agent cannot read its identity from Info.plist, so it will stay idle: \(String(describing: error), privacy: .public)")
}

app.run()
