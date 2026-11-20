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

    /// Final review I1: the comparison by path judges a link by its own path, never where it leads.
    @Test func comparingByPathIgnoresWhereALinkLeads() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SourcePathsTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: downloads)
        #expect(!SourcePaths.containsByPath(home.path, link.path), "the link's own path is outside home")
        #expect(SourcePaths.containsByPath(home.path, downloads.path))
    }

    /// Final review round 2: a folder's name is the last component of the standardised path, by string handling alone.
    /// `URL(fileURLWithPath:)` (which stats the path) keeps `..` as the last component, so these fail if naming goes
    /// back to it.
    @Test func aFoldersNameIsTheLastStandardisedComponent() {
        #expect(SourcePaths.lastComponent("/Volumes/Disk/repo/") == "repo")
        #expect(SourcePaths.lastComponent("/Volumes/Disk/repo/data/x/..") == "data")
        #expect(SourcePaths.lastComponent("/a/./b") == "b")
        #expect(SourcePaths.lastComponent("/") == "/")
        #expect(FolderDrop.name("/Users/me/Pictures/Trips/..") == "Pictures")
        #expect(SourcePaths.standardised("/a//x/../b/") == "/a/b")
        #expect(DefaultExclusions.pattern(forFolder: "/a/x/../b*/") == #"/a/b\*"#)
    }

    @Test func trailingSlashesAndDotDotDontMatter() {
        #expect(SourcePaths.containsByPath("/a/b/", "/a/b/c/"))
        #expect(SourcePaths.containsByPath("/a/b", "/a/x/../b/c"))
        #expect(!SourcePaths.containsByPath("/a/b", "/a/b/../c"))
    }

    /// Seen live 20 Nov 2026: the folder picker stores `/tmp/…` while a typed repository path keeps `/private/tmp/…`.
    /// Only the three firmlinks map, and the comparison reads nothing.
    @Test func privateTmpVarAndEtcAreTheirShortForms() {
        for name in ["tmp", "var", "etc"] {
            #expect(SourcePaths.containsByPath("/\(name)/a", "/private/\(name)/a/repo"))
            #expect(SourcePaths.containsByPath("/private/\(name)/a", "/\(name)/a/repo"))
            #expect(SourcePaths.containsByPath("/private/\(name)/a", "/private/\(name)/a/repo"))
        }
        #expect(!SourcePaths.containsByPath("/tmp", "/private/tmpx"))
        #expect(!SourcePaths.containsByPath("/tmp/a", "/private/tmp/b"))
        #expect(!SourcePaths.containsByPath("/Users/me", "/private/Users/me"))
        #expect(!SourcePaths.containsByPath("/private/Users/me", "/Users/me"))
        #expect(SourcePaths.sameFirmlinkSpelling("/private/var/x", "/var/x/"))
        #expect(!SourcePaths.sameFirmlinkSpelling("/private/var/x", "/var/y"))
    }
}
