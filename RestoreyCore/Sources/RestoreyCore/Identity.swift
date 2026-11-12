import Foundation

/// The identifiers that separate a Debug build from a Release build, so the two never share a
/// launchd label, Mach service, keychain group or on-disk state. Values come from Info.plist keys
/// that the xcconfig files set (`RESTOREY_ROOT_ID` and friends).
public struct Identity: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable {
        /// The Info.plist key is absent, empty, not a string, or still holds an unexpanded `$(VAR)`.
        case missingKey(String)
    }

    /// `com.jaydenkerr.restorey` or, for Debug builds, `com.jaydenkerr.restorey.dev`.
    public let rootID: String
    /// The launchd label, which is also the agent's app Mach service name.
    public let agentLabel: String
    /// `$(AppIdentifierPrefix)` + root ID, already expanded by the build.
    public let keychainAccessGroup: String
    /// `Restorey` or `Restorey-Dev`: the folder name under `~/Library/Logs`.
    public let logsDirectoryName: String

    public var appBundleID: String { rootID }
    public var agentBundleID: String { agentLabel }
    /// The privileged-helper Mach service the agent exposes (spec §8).
    public var helperServiceName: String { agentLabel + ".helper" }

    enum Key {
        static let rootID = "RestoreyRootID"
        static let agentLabel = "RestoreyAgentLabel"
        static let keychainGroup = "RestoreyKeychainGroup"
        static let logsName = "RestoreyLogsName"
    }

    /// Internal so tests can inject a dictionary instead of a real bundle.
    init(infoDictionary: [String: Any]) throws {
        func value(_ key: String) throws -> String {
            guard let string = infoDictionary[key] as? String,
                  !string.isEmpty,
                  !string.contains("$(")
            else { throw Error.missingKey(key) }
            return string
        }
        rootID = try value(Key.rootID)
        agentLabel = try value(Key.agentLabel)
        keychainAccessGroup = try value(Key.keychainGroup)
        logsDirectoryName = try value(Key.logsName)
    }

    public static func fromBundle(_ bundle: Bundle) throws -> Identity {
        try Identity(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public func applicationSupportDirectory() -> URL {
        libraryDirectory("Application Support").appendingPathComponent(rootID, isDirectory: true)
    }

    public func cachesDirectory() -> URL {
        libraryDirectory("Caches").appendingPathComponent(rootID, isDirectory: true)
    }

    public func logsDirectory() -> URL {
        libraryDirectory("Logs").appendingPathComponent(logsDirectoryName, isDirectory: true)
    }

    private func libraryDirectory(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
