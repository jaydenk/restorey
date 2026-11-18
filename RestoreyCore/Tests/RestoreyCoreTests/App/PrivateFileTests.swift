import Foundation
import Testing

@testable import RestoreyCore

/// The recovery kit's PDF is written where the user picks (UI design §7): readable only by them from the first
/// byte, and never left half-written beside the target.
@Suite struct PrivateFileTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
    }

    static func others(in folder: URL, besides name: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != name }
    }

    @Test func theTemporaryFileIsPrivateBeforeItIsRenamedAndTheTargetEndsUpPrivate() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("kit.pdf")
        // With the usual umask (022) a file created and then narrowed would be seen at 0644 here.
        var seen: (path: String, mode: Int, bytes: Data)?
        try PrivateFile.write(Data("secret kit".utf8), to: target) { temporary in
            seen = (temporary.path, try Self.mode(temporary.path), try Data(contentsOf: temporary))
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
        #expect(seen?.mode == 0o600)
        #expect(seen?.bytes == Data("secret kit".utf8))
        #expect(seen.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } == folder.path)
        #expect(try Self.mode(target.path) == 0o600)
        #expect(try Data(contentsOf: target) == Data("secret kit".utf8))
        #expect(try Self.others(in: folder, besides: "kit.pdf").isEmpty)
    }

    @Test func replacingAnOpenFileLeavesItPrivate() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("kit.pdf")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try PrivateFile.write(Data("new".utf8), to: target)
        #expect(try Self.mode(target.path) == 0o600)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
    }

    struct Injected: Error {}

    @Test func aFailedWriteLeavesNoTemporaryFileAndTheOldTargetAlone() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("kit.pdf")
        try Data("old".utf8).write(to: target)
        #expect(throws: Injected.self) {
            try PrivateFile.write(Data("new".utf8), to: target) { _ in throw Injected() }
        }
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try Self.others(in: folder, besides: "kit.pdf").isEmpty)
    }

    @Test func aFolderThatCantBeWrittenFailsWithASentenceAndLeavesNothing() throws {
        let folder = try Self.folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect {
            try PrivateFile.write(Data("kit".utf8), to: folder.appendingPathComponent("kit.pdf"))
        } throws: { error in
            String(describing: error).contains("Restorey couldn’t save") && String(describing: error).contains("kit.pdf")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
