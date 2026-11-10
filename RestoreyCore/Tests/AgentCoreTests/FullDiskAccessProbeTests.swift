import Foundation
import Testing
@testable import AgentCore

/// The probe lists a protected folder in a stand-in home. An unreadable folder is how a missing
/// grant looks to the agent (NSCocoaError 257), so `chmod 000` stands in for TCC here.
struct FullDiskAccessProbeTests {
    final class Home: Sendable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("restorey-fda-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("Library"), withIntermediateDirectories: true)
        }
        deinit {
            for name in FullDiskAccessProbe.protectedDirectories {
                chmod(url.appendingPathComponent(name).path, 0o700)
            }
            try? FileManager.default.removeItem(at: url)
        }
        func make(_ name: String, mode: mode_t = 0o700) throws {
            let dir = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent("item"), atomically: true, encoding: .utf8)
            chmod(dir.path, mode)
        }
    }

    @Test func readableProtectedFolderIsGranted() throws {
        let home = try Home()
        try home.make("Library/Mail")
        #expect(FullDiskAccessProbe.probe(home: home.url) == .granted)
    }

    @Test func unreadableProtectedFolderIsMissing() throws {
        let home = try Home()
        try home.make("Library/Safari", mode: 0)
        #expect(FullDiskAccessProbe.probe(home: home.url) == .missing)
    }

    /// Only the first folder that exists is listed: a readable later one does not hide a refusal.
    @Test func firstExistingFolderDecides() throws {
        let home = try Home()
        try home.make("Library/Mail", mode: 0)
        try home.make("Library/Messages")
        #expect(FullDiskAccessProbe.probe(home: home.url) == .missing)
    }

    @Test func noProtectedFolderCannotBeVerified() throws {
        let home = try Home()
        #expect(FullDiskAccessProbe.probe(home: home.url) == .cannotVerify)
    }

    /// A file where the folder should be is not something the probe can judge.
    @Test func aFileInsteadOfAFolderCannotBeVerified() throws {
        let home = try Home()
        try "x".write(to: home.url.appendingPathComponent("Library/Safari"), atomically: true, encoding: .utf8)
        #expect(FullDiskAccessProbe.probe(home: home.url) == .cannotVerify)
    }

    @Test func candidatesAreSafariMailAndMessagesInThatOrder() {
        #expect(FullDiskAccessProbe.protectedDirectories == ["Library/Safari", "Library/Mail", "Library/Messages"])
    }
}
