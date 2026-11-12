import Foundation
import Testing
@testable import RestoreyCore

@Suite struct IdentityTests {
    private static var debugInfo: [String: Any] { [
        "RestoreyRootID": "com.jaydenkerr.restorey.dev",
        "RestoreyAgentLabel": "com.jaydenkerr.restorey.dev.agent",
        "RestoreyKeychainGroup": "ABCDE12345.com.jaydenkerr.restorey.dev",
        "RestoreyLogsName": "Restorey-Dev",
    ] }

    private static var releaseInfo: [String: Any] { [
        "RestoreyRootID": "com.jaydenkerr.restorey",
        "RestoreyAgentLabel": "com.jaydenkerr.restorey.agent",
        "RestoreyKeychainGroup": "ABCDE12345.com.jaydenkerr.restorey",
        "RestoreyLogsName": "Restorey",
    ] }

    @Test func decodesDebugAndReleaseKeys() throws {
        let dev = try Identity(infoDictionary: Self.debugInfo)
        #expect(dev.rootID == "com.jaydenkerr.restorey.dev")
        #expect(dev.appBundleID == "com.jaydenkerr.restorey.dev")
        #expect(dev.agentLabel == "com.jaydenkerr.restorey.dev.agent")
        #expect(dev.agentBundleID == "com.jaydenkerr.restorey.dev.agent")
        #expect(dev.helperServiceName == dev.agentLabel + ".helper")
        #expect(dev.keychainAccessGroup == "ABCDE12345.com.jaydenkerr.restorey.dev")
        #expect(dev.logsDirectory().lastPathComponent == "Restorey-Dev")

        let release = try Identity(infoDictionary: Self.releaseInfo)
        #expect(release.rootID == "com.jaydenkerr.restorey")
        #expect(release.helperServiceName == "com.jaydenkerr.restorey.agent.helper")
        #expect(release.logsDirectory().lastPathComponent == "Restorey")
    }

    @Test func derivedDirectoriesAreKeyedByRootID() throws {
        let dev = try Identity(infoDictionary: Self.debugInfo)
        #expect(dev.applicationSupportDirectory().lastPathComponent == "com.jaydenkerr.restorey.dev")
        #expect(dev.applicationSupportDirectory().deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(dev.cachesDirectory().lastPathComponent == "com.jaydenkerr.restorey.dev")
        #expect(dev.cachesDirectory().deletingLastPathComponent().lastPathComponent == "Caches")
        #expect(dev.logsDirectory().deletingLastPathComponent().lastPathComponent == "Logs")
    }

    @Test(arguments: ["RestoreyRootID", "RestoreyAgentLabel", "RestoreyKeychainGroup", "RestoreyLogsName"])
    func missingKeyThrows(key: String) {
        var info = Self.debugInfo
        info.removeValue(forKey: key)
        #expect(throws: Identity.Error.missingKey(key)) {
            try Identity(infoDictionary: info)
        }
    }

    @Test func emptyOrNonStringValueCountsAsMissing() {
        var info = Self.debugInfo
        info["RestoreyAgentLabel"] = ""
        #expect(throws: Identity.Error.missingKey("RestoreyAgentLabel")) {
            try Identity(infoDictionary: info)
        }
        info["RestoreyAgentLabel"] = 42
        #expect(throws: Identity.Error.missingKey("RestoreyAgentLabel")) {
            try Identity(infoDictionary: info)
        }
    }

    @Test func unexpandedBuildSettingCountsAsMissing() {
        // A "$(VAR)" left in Info.plist means the xcconfig variable was never defined.
        var info = Self.debugInfo
        info["RestoreyKeychainGroup"] = "$(AppIdentifierPrefix)com.jaydenkerr.restorey.dev"
        #expect(throws: Identity.Error.missingKey("RestoreyKeychainGroup")) {
            try Identity(infoDictionary: info)
        }
    }
}

@Suite struct OwnLogExclusionTests {
    private static let home = URL(fileURLWithPath: "/Users/test")

    private static func identity(root: String, logs: String) throws -> Identity {
        try Identity(infoDictionary: [
            "RestoreyRootID": root, "RestoreyAgentLabel": root + ".agent",
            "RestoreyKeychainGroup": "ABCDE12345." + root, "RestoreyLogsName": logs,
        ])
    }

    @Test func devIdentityExcludesItsOwnLogsAndSupportFolders() throws {
        let dev = try Self.identity(root: "com.jaydenkerr.restorey.dev", logs: "Restorey-Dev")
        let base = DefaultExclusions.paths(home: Self.home)
        let paths = DefaultExclusions.paths(home: Self.home, identity: dev)
        #expect(Array(paths.prefix(base.count)) == base)
        #expect(Array(paths.dropFirst(base.count)) == [
            "/Users/test/Library/Logs/Restorey-Dev",
            "/Users/test/Library/Application Support/com.jaydenkerr.restorey.dev",
        ])
    }

    @Test func releaseIdentityExcludesItsOwnLogsAndSupportFolders() throws {
        let release = try Self.identity(root: "com.jaydenkerr.restorey", logs: "Restorey")
        let paths = DefaultExclusions.paths(home: Self.home, identity: release)
        #expect(paths.contains("/Users/test/Library/Logs/Restorey"))
        #expect(paths.contains("/Users/test/Library/Application Support/com.jaydenkerr.restorey"))
        #expect(!paths.contains("/Users/test/Library/Logs/Restorey-Dev"))
    }

    @Test func publicOverloadAddsTheSamePaths() throws {
        let dev = try Self.identity(root: "com.jaydenkerr.restorey.dev", logs: "Restorey-Dev")
        let paths = DefaultExclusions.paths(home: Self.home, identity: dev)
        #expect(paths.contains("/Users/test/Library/Logs/Restorey-Dev"))
        #expect(paths.contains("/Users/test/Library/Application Support/com.jaydenkerr.restorey.dev"))
        #expect(DefaultExclusions.paths(home: Self.home).count < paths.count)
    }
}
