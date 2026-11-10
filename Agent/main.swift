import AppKit
import Foundation
import OSLog
import RestoreyCore

// The agent is started by launchd from the LaunchAgent plist embedded in the app bundle.
// A real NSApplication run loop gives it a full app identity for UserNotifications later on.
let agentLog = Logger(subsystem: "com.jaydenkerr.restorey", category: "agent")

do {
    let identity = try Identity.fromBundle(.main)
    agentLog.notice("agent started, label \(identity.agentLabel, privacy: .public), pid \(getpid())")
} catch {
    agentLog.fault("agent cannot read its identity from Info.plist: \(String(describing: error), privacy: .public)")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
