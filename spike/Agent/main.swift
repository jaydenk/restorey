import AppKit
import Foundation

// Command-line mode: restic's RESTIC_PASSWORD_COMMAND runs this executable directly.
// It prints the secret to stdout and never prompts (spec §7).
let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "print-password" {
    let account = arguments.firstIndex(of: "--account").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        ?? SpikeIDs.keychainAccount
    let (value, status) = SpikeKeychain.read(account: account)
    guard let value else {
        FileHandle.standardError.write(Data("print-password: \(SpikeKeychain.describe(status))\n".utf8))
        exit(1)
    }
    FileHandle.standardOutput.write(Data(value.utf8))
    exit(0)
}

// Agent mode: launchd starts this via the embedded LaunchAgent plist.
let service = AgentService()
let listener = NSXPCListener(machServiceName: SpikeIDs.agentLabel)
if let team = Bundle.main.object(forInfoDictionaryKey: "SpikeTeamID") as? String, !team.isEmpty {
    // Only the spike app (same team) may connect.
    listener.setConnectionCodeSigningRequirement(
        "identifier \"\(SpikeIDs.appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
}
listener.delegate = service
listener.resume()
agentLog.notice("agent started, pid \(getpid()), build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
service.startupHook()

// A real NSApplication run loop gives the helper a full app identity for UserNotifications.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
