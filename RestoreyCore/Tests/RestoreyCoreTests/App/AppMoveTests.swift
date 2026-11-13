import Darwin
import Foundation
import Testing

@testable import RestoreyCore

@Suite struct AppMoveTests {
    // MARK: Decision and paths

    @Test func nothingThereMoves() {
        #expect(AppMove.decision(destinationExists: false, destinationAgentRegistered: false) == .move)
        // A registration with no copy to replace doesn't stop the move.
        #expect(AppMove.decision(destinationExists: false, destinationAgentRegistered: true) == .move)
    }

    @Test func anUnregisteredCopyIsOfferedForReplacing() {
        #expect(AppMove.decision(destinationExists: true, destinationAgentRegistered: false) == .replace)
    }

    @Test func aCopyWithItsAgentRegisteredIsRefused() {
        #expect(AppMove.decision(destinationExists: true, destinationAgentRegistered: true) == .refuse)
        #expect(AppMoveError.refused.description == AppMove.refusal)
        #expect(AppMove.refusal.contains("Quit Restorey"))
        #expect(AppMove.refusal.contains("by hand"))
    }

    @Test func destinationKeepsTheBundleName() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        #expect(AppMove.destination(for: URL(fileURLWithPath: "/Users/me/Downloads/RestoreyDev.app"), applications: applications).path
            == "/Applications/RestoreyDev.app")
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Restorey.app")
        #expect(AppMove.destination(for: translocated, applications: applications).path == "/Applications/Restorey.app")
    }

    @Test func permissionErrorsGetTheirOwnSentence() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(AppMove.error(from: cocoa) == .noPermission)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(AppMove.error(from: posix) == .noPermission)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(AppMove.error(from: wrapped) == .noPermission)
        #expect(AppMove.error(from: AppMoveError.refused) == .refused)
        if case .failed = AppMove.error(from: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) {
        } else {
            Issue.record("a full disk is a plain failure")
        }
    }

    // MARK: Installing (temporary folders)

    private final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-move-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// A small bundle: a marker file, a nested folder and a symbolic link, the first two quarantined.
    private static func makeBundle(in folder: URL, marker: String) throws -> URL {
        let bundle = folder.appendingPathComponent("RestoreyDev.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let file = macOS.appendingPathComponent("RestoreyDev")
        try Data(marker.utf8).write(to: file)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("Contents/Current"), withDestinationURL: macOS)
        for path in [bundle.path, file.path] { try quarantine(path) }
        return bundle
    }

    private static func quarantine(_ path: String) throws {
        let value = Array("0083;00000000;Safari;".utf8)
        guard setxattr(path, AppMove.quarantineAttribute, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, AppMove.quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func marker(_ bundle: URL) throws -> String {
        String(decoding: try Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/RestoreyDev")), as: UTF8.self)
    }

    @Test func installsACopyWithoutQuarantine() throws {
        let downloads = try Folder(), applications = try Folder()
        let source = try Self.makeBundle(in: downloads.url, marker: "new")
        let destination = AppMove.destination(for: source, applications: applications.url)
        try AppInstaller().install(source, at: destination, replacing: false)

        #expect(try Self.marker(destination) == "new")
        #expect(!Self.isQuarantined(destination.path))
        #expect(!Self.isQuarantined(destination.appendingPathComponent("Contents/MacOS/RestoreyDev").path))
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("Contents/Current").path)
        #expect(link.hasSuffix("Contents/MacOS"))
        // The source is left as it was; nothing else is left in Applications.
        #expect(Self.isQuarantined(source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.url.path) == ["RestoreyDev.app"])
    }

    @Test func replacesAnExistingCopyOnlyWhenAsked() throws {
        let downloads = try Folder(), applications = try Folder()
        let source = try Self.makeBundle(in: downloads.url, marker: "new")
        let old = try Self.makeBundle(in: applications.url, marker: "old")

        #expect(throws: AppMoveError.destinationExists) {
            try AppInstaller().install(source, at: old, replacing: false)
        }
        #expect(try Self.marker(old) == "old")

        try AppInstaller().install(source, at: old, replacing: true)
        #expect(try Self.marker(old) == "new")
        #expect(!Self.isQuarantined(old.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.url.path) == ["RestoreyDev.app"])
    }

    @Test func aFailedCopyLeavesNothingAtTheDestination() throws {
        let downloads = try Folder(), applications = try Folder()
        let missing = downloads.url.appendingPathComponent("RestoreyDev.app")
        let destination = AppMove.destination(for: missing, applications: applications.url)
        #expect(throws: (any Error).self) { try AppInstaller().install(missing, at: destination, replacing: false) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aReadOnlyApplicationsFolderIsANoPermissionError() throws {
        let downloads = try Folder(), applications = try Folder()
        let source = try Self.makeBundle(in: downloads.url, marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.url.path) }
        let destination = AppMove.destination(for: source, applications: applications.url)
        do {
            try AppInstaller().install(source, at: destination, replacing: false)
            Issue.record("installed into a read-only folder")
        } catch {
            #expect(AppMove.error(from: error) == .noPermission)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
