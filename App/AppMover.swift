import AppKit
import Darwin
import RestoreyCore

/// Setup's "Move to Applications" (UI design §4): copies this copy into /Applications, clears its quarantine,
/// opens the moved copy and quits. Exists only for a copy that `InstallLocation.check` refused, and touches
/// nothing of the agent's: whether the installed copy's agent is registered is read from launchd and from the
/// app's own record of its last registration, never from `SMAppService`, whose status read alone re-points
/// the registration at the reading copy (spike phase B).
///
/// It never asks for an administrator password. `NSWorkspace.requestAuthorization(to: .replaceFile)` needs
/// the restricted Privileged File Operations entitlement, which a Developer ID app doesn't get, and
/// /Applications is writable by every administrator (`root:admin`, mode 775). Anyone else gets
/// `AppMove.noPermission`: drag it there in Finder.
@MainActor
struct AppMover {
    let source: URL
    let identity: Identity
    var applications = InstallLocation.applications

    var destination: URL { AppMove.destination(for: source, applications: applications) }

    /// Read afresh each time: the user may have set up or removed the other copy since the screen opened.
    func decision() -> AppMoveDecision {
        AppMove.decision(
            destinationExists: FileManager.default.fileExists(atPath: destination.path),
            destinationAgentRegistered: agentIsRegistered())
    }

    /// Moves the app and opens the moved copy; this copy then quits. Throws `AppMoveError`. `.replace` is the
    /// screen's to confirm before calling; a copy whose agent is registered is refused here whatever the
    /// screen showed.
    @discardableResult
    func move() async throws -> URL {
        let decision = decision()
        guard decision != .refuse else { throw AppMoveError.refused }
        let source = source, destination = destination
        do {
            try await Task.detached {
                try AppInstaller().install(source, at: destination, replacing: decision == .replace)
            }.value
        } catch {
            throw AppMove.error(from: error)
        }
        // The copy left behind would open as a second, refused Restorey. A read-only disk image keeps it.
        try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        let configuration = NSWorkspace.OpenConfiguration()
        // Same bundle identifier as this running copy, so Launch Services would otherwise just activate it.
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        } catch {
            throw AppMoveError.failed("it's in Applications, but didn't open: \(error.localizedDescription)")
        }
        NSApplication.shared.terminate(nil)
        return destination
    }

    /// The installed copy records the agent plist's hash at every `register()` and removes it at `unregister()`
    /// (`AgentRegistration`); launchd lists the job while it is loaded. Either one counts, so a copy that may
    /// be running a backup is never replaced.
    private func agentIsRegistered() -> Bool {
        if UserDefaults.standard.string(forKey: AgentRegistration.plistHashKey) != nil { return true }
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", "gui/\(getuid())/\(identity.agentLabel)"]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        do {
            try launchctl.run()
        } catch {
            // Unknown: treat as registered, the safe side.
            return true
        }
        launchctl.waitUntilExit()
        return launchctl.terminationStatus == 0
    }
}
