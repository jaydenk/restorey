import Foundation
import Testing
@testable import RestoreyCore

/// Whether one folder is another or lies below it, compared by whole path components (Task 1). Two entry points: by
/// path alone (no file system access, for validation and scheduling) and following links (where the user acts).
struct SourcePathsTests {
    @Test func aFolderContainsItselfAndItsDescendants() {
        #expect(SourcePaths.containsByPath("/a", "/a"))
        #expect(SourcePaths.containsByPath("/a", "/a/b"))
        #expect(SourcePaths.containsByPath("/a", "/a/b/c"))
        #expect(!SourcePaths.containsByPath("/a/b", "/a"))
    }

    @Test func aSiblingWhoseNameStartsTheSameIsNotCovered() {
        #expect(!SourcePaths.containsByPath("/Users/me/Doc", "/Users/me/Documents"))
        #expect(!SourcePaths.containsByPath("/Volumes/Backup", "/Volumes/Backups"))
        #expect(!SourcePaths.containsByPath("/Volumes/Backup", "/Volumes/Backups/data"))
    }

    @Test func aFolderReachedThroughASymlinkIsCoveredWhenFollowingLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourcePathsTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: downloads)
        #expect(SourcePaths.containsFollowingLinks(home.path, link.path))
        #expect(!SourcePaths.containsFollowingLinks(link.path, home.path))
    }

    /// Final review I1: the comparison by path never reads the file system, so a hung network volume can't stall
    /// the agent's status or schedule. A link that leads inside the folder is judged by its own path, and a folder
    /// whose parent can't even be read (permissions 000) is compared as written.
    @Test func comparingByPathIgnoresWhereALinkLeadsAndNeverReadsTheDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourcePathsTests-\(UUID().uuidString)")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? fm.removeItem(at: root)
        }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: downloads)
        #expect(!SourcePaths.containsByPath(home.path, link.path), "the link's own path is outside home")
        #expect(SourcePaths.containsByPath(home.path, downloads.path))

        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked.appendingPathComponent("repo/data"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(SourcePaths.containsByPath(locked.appendingPathComponent("repo").path,
                                           locked.appendingPathComponent("repo/data").path))
        #expect(!SourcePaths.containsByPath(locked.appendingPathComponent("repo/data").path,
                                            locked.appendingPathComponent("repo").path))
    }

    @Test func trailingSlashesAndDotDotDontMatter() {
        #expect(SourcePaths.containsByPath("/a/b/", "/a/b/c/"))
        #expect(SourcePaths.containsByPath("/a/b", "/a/x/../b/c"))
        #expect(!SourcePaths.containsByPath("/a/b", "/a/b/../c"))
    }
}
