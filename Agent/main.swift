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
        Task { @MainActor in
            let secrets = KeychainSecretStore(service: identity.rootID, accessGroup: identity.keychainAccessGroup)
            let state = await AgentState(
                directory: identity.applicationSupportDirectory(), secrets: secrets, now: { Date() })
            if let configError = await state.status().configError {
                log.error("Not running any plan until the settings are fixed: \(configError)")
            }
            let service = AgentService(state: state, log: log) {
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
