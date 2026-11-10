import Foundation
import Testing
@testable import RestoreyCore

struct ExecutableFingerprintTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sameFileGivesTheSameFingerprint() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Agent")
        try Data("one".utf8).write(to: file)
        let first = ExecutableFingerprint.of(file)
        #expect(first != nil)
        #expect(ExecutableFingerprint.of(file) == first)
    }

    /// An install removes the bundle and copies a new one (`rm -rf` then `ditto`, or Sparkle), keeping the
    /// modification time: the fingerprint still changes, because the file is a new one.
    @Test func replacedFileChangesEvenWithTheSameContentsAndDate() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Agent")
        try Data("same".utf8).write(to: file)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let before = ExecutableFingerprint.of(file)
        let copy = dir.appendingPathComponent("Agent.new")
        try Data("same".utf8).write(to: copy)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: copy.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: copy, to: file)
        #expect(ExecutableFingerprint.of(file) != before)
    }

    @Test func missingFileHasNone() {
        #expect(ExecutableFingerprint.of(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")) == nil)
    }
}
