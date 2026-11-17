import AppKit
import Darwin
import RestoreyCore

/// Setup's "Move to Applications" (UI design §4): copies this copy into /Applications under the build's own name,
/// clears its quarantine, opens the moved copy and quits. Exists only for a copy that `InstallLocation.check`
/// refused. The decisions and file work are `AppMove`'s and `AppMoveRunner`'s in RestoreyCore; this adds what
/// they read from the system (`SystemAppMoveProbe`) and the relaunch.
///
/// It never asks for an administrator password. `NSWorkspace.requestAuthorization(to: .replaceFile)` needs
/// the restricted Privileged File Operations entitlement, which a Developer ID app doesn't get, and
/// /Applications is writable by every administrator (`root:admin`, mode 775). Anyone else is told to drag the
/// app there in Finder (`AppMoveRefusal.noPermission`).
@MainActor
struct AppMover {
    let identity: Identity
    let destination: URL
    /// The copy to send to the Trash once moved: for a translocated launch, the original it came from.
    let copyToTrash: URL?
    private let source: URL
    private let probe: SystemAppMoveProbe

    init(bundle: Bundle, identity: Identity, translocated: Bool) {
        self.identity = identity
        source = bundle.bundleURL
        let productName = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        destination = AppMove.destination(productName: productName, applications: InstallLocation.applications)
        copyToTrash = AppMove.copyToTrash(
            bundleURL: source, translocated: translocated,
            original: translocated ? InstallLocation.originalURL(ofTranslocated: source) : nil)
        probe = SystemAppMoveProbe(agentLabel: identity.agentLabel)
    }

    /// Read afresh each time: the user may have set up or removed the other copy since the screen opened.
    func decision() async -> AppMoveDecision {
        await AppMove.decide(probe: probe, destination: destination, bundleID: identity.appBundleID)
    }

    /// Moves the app (deciding again, so a stale screen can't replace anything) and opens the moved copy; this
    /// copy then quits. Throws `AppMoveError`.
    func move() async throws {
        try await AppMoveRunner(probe: probe).run(
            source: source, destination: destination, bundleID: identity.appBundleID, copyToTrash: copyToTrash)
        let configuration = NSWorkspace.OpenConfiguration()
        // Same bundle identifier as this running copy, so Launch Services would otherwise just activate it.
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        } catch {
            throw AppMoveError.failed("it’s in Applications, but didn’t open: \(error.localizedDescription)")
        }
        NSApplication.shared.terminate(nil)
    }
}

/// What the move reads from this Mac. Whether an agent is registered comes from the installed copy's record of
/// its last `register()` (`AgentRegistration.plistHashKey`, removed at `unregister()`) and from launchd, never
/// from `SMAppService`, whose status read alone re-points the registration at the reading copy (spike phase B).
/// Either counts, so a copy that may be running a backup is never touched.
struct SystemAppMoveProbe: AppMoveProbe {
    let agentLabel: String

    func agentRegistered() async -> Bool {
        if UserDefaults.standard.string(forKey: AgentRegistration.plistHashKey) != nil { return true }
        return await launchdHasJob()
    }

    func destinationState(_ url: URL) -> AppMoveDestinationState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        return .present(bundleID: Bundle(url: url)?.bundleIdentifier)
    }

    func isWritable(_ directory: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: directory.path)
    }

    /// `launchctl print gui/<uid>/<label>` succeeds while launchd holds the job. Awaited, never blocking the
    /// main actor. A launchctl that can't run counts as registered, the safe side.
    private func launchdHasJob() async -> Bool {
        await withCheckedContinuation { continuation in
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["print", "gui/\(getuid())/\(agentLabel)"]
            launchctl.standardOutput = FileHandle.nullDevice
            launchctl.standardError = FileHandle.nullDevice
            launchctl.terminationHandler = { process in continuation.resume(returning: process.terminationStatus == 0) }
            do {
                try launchctl.run()
            } catch {
                launchctl.terminationHandler = nil
                continuation.resume(returning: true)
            }
        }
    }
}
