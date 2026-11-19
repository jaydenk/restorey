import Foundation
import Testing
@testable import RestoreyCore

/// Whether one folder is another or lies below it, compared by whole path components (Task 1).
struct SourcePathsTests {
    @Test func aFolderContainsItselfAndItsDescendants() {
        #expect(SourcePaths.contains("/a", "/a"))
        #expect(SourcePaths.contains("/a", "/a/b"))
        #expect(SourcePaths.contains("/a", "/a/b/c"))
        #expect(!SourcePaths.contains("/a/b", "/a"))
    }

    @Test func aSiblingWhoseNameStartsTheSameIsNotCovered() {
        #expect(!SourcePaths.contains("/Users/me/Doc", "/Users/me/Documents"))
        #expect(!SourcePaths.contains("/Volumes/Backup", "/Volumes/Backups"))
        #expect(!SourcePaths.contains("/Volumes/Backup", "/Volumes/Backups/data"))
    }

    @Test func aFolderReachedThroughASymlinkIsStillCovered() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourcePathsTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: downloads)
        #expect(SourcePaths.contains(home.path, link.path))
        #expect(!SourcePaths.contains(link.path, home.path))
    }

    @Test func trailingSlashesAndDotDotDontMatter() {
        #expect(SourcePaths.contains("/a/b/", "/a/b/c/"))
        #expect(SourcePaths.contains("/a/b", "/a/x/../b/c"))
        #expect(!SourcePaths.contains("/a/b", "/a/b/../c"))
    }
}
