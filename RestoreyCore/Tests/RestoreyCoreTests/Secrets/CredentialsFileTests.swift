import Foundation
import Testing
@testable import RestoreyCore

@Suite struct CredentialsFileTests {
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString)", isDirectory: true)
    }

    private static func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private static let helper = URL(fileURLWithPath: "/Applications/RestoreyDev.app/Contents/Helpers/RestoreyDevAgent.app/Contents/MacOS/RestoreyDevAgent")

    @Test func exactContents() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = UUID()
        let file = try CredentialsFile.write(planID: plan, helper: Self.helper, directory: dir)
        #expect(file.lastPathComponent == "\(plan.uuidString).ini")
        #expect(file.deletingLastPathComponent().lastPathComponent == "s3")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "[restorey-\(plan.uuidString)]\ncredential_process = \(Self.helper.path) s3-credentials --plan \(plan.uuidString)\n")
    }

    @Test func modeIs0600AndDirectory0700() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A pre-existing, too-open s3 folder must be tightened.
        let s3 = dir.appendingPathComponent("s3", isDirectory: true)
        try FileManager.default.createDirectory(at: s3, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = try CredentialsFile.write(planID: UUID(), helper: Self.helper, directory: dir)
        #expect(try Self.mode(file) == 0o600)
        #expect(try Self.mode(file.deletingLastPathComponent()) == 0o700)
    }

    @Test(arguments: [
        "/Applications/Restorey Dev.app/agent",
        "/tmp/a\tb/agent",
        "/tmp/a\nb/agent",
        "/tmp/a\u{00A0}b/agent",
        "/tmp/a\u{2003}b/agent",
    ])
    func refusesHelperPathWithWhitespace(path: String) {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CredentialsFile.Error.pathContainsWhitespace(path)) {
            try CredentialsFile.write(planID: UUID(), helper: URL(fileURLWithPath: path), directory: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("s3").path))
    }

    @Test func rewriteIsIdempotentAndLeavesNoTemporaryFiles() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = UUID()
        let first = try CredentialsFile.write(planID: plan, helper: Self.helper, directory: dir)
        let firstText = try String(contentsOf: first, encoding: .utf8)
        let second = try CredentialsFile.write(planID: plan, helper: Self.helper, directory: dir)
        #expect(first == second)
        #expect(try String(contentsOf: second, encoding: .utf8) == firstText)
        #expect(try Self.mode(second) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path)
        #expect(names == ["\(plan.uuidString).ini"])
    }

    @Test(arguments: ["/tmp/a#b/agent", "/tmp/a;b/agent"])
    func refusesCommentCharacters(path: String) {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CredentialsFile.Error.pathContainsCommentCharacter(path)) {
            try CredentialsFile.write(planID: UUID(), helper: URL(fileURLWithPath: path), directory: dir)
        }
    }

    @Test func failedRenameThrowsAndRemovesTemporaryFile() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = UUID()
        // A non-empty directory where the file should go makes rename(2) fail.
        let blocker = dir.appendingPathComponent("s3/\(plan.uuidString).ini", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        #expect(throws: CredentialsFile.Error.self) {
            try CredentialsFile.write(planID: plan, helper: Self.helper, directory: dir)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("s3").path)
        #expect(names == ["\(plan.uuidString).ini"])
    }
}
