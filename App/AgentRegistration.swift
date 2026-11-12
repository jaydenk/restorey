import CryptoKit
import Foundation
import RestoreyCore
import ServiceManagement

/// The agent's `SMAppService` registration. The only file in the app that imports ServiceManagement, and
/// it can only be made for the installed copy (`InstalledCopy`).
@MainActor
final class AgentRegistration {
    /// The SHA-256 of the embedded plist at the last successful `register()`. launchd keeps the job
    /// definition from registration, so a changed plist needs a re-registration (spike, spec §8).
    static let plistHashKey = "agentPlistSHA256"

    private let service: SMAppService
    private let plistURL: URL
    private let defaults: UserDefaults

    init(installed: InstalledCopy, identity: Identity, defaults: UserDefaults = .standard) {
        let plistName = "\(identity.agentLabel).plist"
        service = SMAppService.agent(plistName: plistName)
        plistURL = installed.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        self.defaults = defaults
    }

    /// Reads `SMAppService.status`. An unknown future value is treated like `requiresApproval`: shown,
    /// never acted on.
    var status: AgentServiceStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .requiresApproval
        }
    }

    var storedPlistHash: String? { defaults.string(forKey: Self.plistHashKey) }

    /// The SHA-256 of the plist embedded in this bundle, in lower-case hex.
    func currentPlistHash() throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: plistURL))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Registers the embedded agent and records the plist's hash. The hash is read first, so a plist that
    /// can't be read is never registered.
    func register() throws {
        let hash = try currentPlistHash()
        try service.register()
        defaults.set(hash, forKey: Self.plistHashKey)
    }

    /// Stops the agent (and any restic it runs) and removes the job. Callers drain first.
    func unregister() async throws {
        defaults.removeObject(forKey: Self.plistHashKey)
        try await service.unregister()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
