import Darwin
import Foundation
import Testing

@testable import RestoreyCore

@Suite struct AppMoveTests {
    private static let bundleID = "com.jaydenkerr.restorey.dev"

    // MARK: Decision

    private static func decide(
        registered: Bool = false, destination: AppMoveDestinationState = .absent, writable: Bool = true
    ) -> AppMoveDecision {
        AppMove.decision(
            agentRegistered: registered, destination: destination, bundleID: bundleID, applicationsWritable: writable)
    }

    @Test func nothingThereMoves() {
        #expect(Self.decide() == .move)
    }

    @Test func anyRegisteredAgentRefusesWhateverIsAtTheDestination() {
        // Design §4: the screen only works before any agent is registered, so a second download saved as
        // "Restorey 2.app" can't move in beside a registered copy either.
        #expect(Self.decide(registered: true) == .refuse(.agentRegistered))
        #expect(Self.decide(registered: true, destination: .present(bundleID: Self.bundleID)) == .refuse(.agentRegistered))
        #expect(Self.decide(registered: true, destination: .present(bundleID: "com.example.other")) == .refuse(.agentRegistered))
        #expect(AppMoveError.refused(.agentRegistered).description == AppMove.refusal)
        #expect(AppMove.refusal.contains("Quit Restorey"))
        #expect(AppMove.refusal.contains("by hand"))
    }

    @Test func thisRestoreyIsOfferedForReplacingOnlyWithoutAnAgent() {
        #expect(Self.decide(destination: .present(bundleID: Self.bundleID)) == .replace)
    }

    @Test func anotherAppAtTheDestinationIsNeverReplaced() {
        #expect(Self.decide(destination: .present(bundleID: "com.jaydenkerr.restorey")) == .refuse(.otherApp))
        #expect(Self.decide(destination: .present(bundleID: nil)) == .refuse(.otherApp))
        #expect(AppMoveError.refused(.otherApp).description == AppMove.otherApp)
    }

    @Test func anUnwritableApplicationsFolderRefusesUpFront() {
        #expect(Self.decide(writable: false) == .refuse(.noPermission))
        #expect(Self.decide(destination: .present(bundleID: Self.bundleID), writable: false) == .refuse(.noPermission))
    }

    // MARK: Paths

    @Test func destinationIsTheBuildsOwnName() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        #expect(AppMove.destination(productName: "RestoreyDev", applications: applications).path
            == "/Applications/RestoreyDev.app")
        #expect(AppMove.destination(productName: "Restorey", applications: applications).path
            == "/Applications/Restorey.app")
    }

    @Test func aTranslocatedLaunchTrashesTheOriginalNeverTheMount() {
        let mount = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Restorey.app")
        let original = URL(fileURLWithPath: "/Users/me/Downloads/Restorey 2.app")
        #expect(AppMove.copyToTrash(bundleURL: mount, translocated: true, original: original) == original)
        #expect(AppMove.copyToTrash(bundleURL: mount, translocated: true, original: nil) == nil)
        let plain = URL(fileURLWithPath: "/Users/me/Downloads/Restorey.app")
        #expect(AppMove.copyToTrash(bundleURL: plain, translocated: false, original: nil) == plain)
    }

    @Test func permissionErrorsGetTheirOwnSentence() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(AppMove.error(from: cocoa) == .refused(.noPermission))
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(AppMove.error(from: posix) == .refused(.noPermission))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(AppMove.error(from: wrapped) == .refused(.noPermission))
        #expect(AppMove.error(from: AppMoveError.refused(.otherApp)) == .refused(.otherApp))
        if case .failed = AppMove.error(from: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) {
        } else {
            Issue.record("a full disk is a plain failure")
        }
    }

    // MARK: Installing (temporary folders)

    final class Folder: Sendable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("restorey-move-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func folder(_ name: String) throws -> URL {
            let made = url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            return made
        }
    }

    /// A small bundle: a marker file, a nested folder and a symbolic link, the first two quarantined.
    static func makeBundle(in folder: URL, name: String = "RestoreyDev.app", marker: String) throws -> URL {
        let bundle = folder.appendingPathComponent(name, isDirectory: true)
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

    static func marker(_ bundle: URL) throws -> String {
        String(decoding: try Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/RestoreyDev")), as: UTF8.self)
    }

    /// An installer whose staging folder and "Trash" are inside `folder`, so tests can see both.
    static func installer(in folder: Folder) throws -> (AppInstaller, staging: URL, trash: URL) {
        let staging = folder.url.appendingPathComponent("staging", isDirectory: true)
        let trash = try folder.folder("trash")
        let installer = AppInstaller(
            stagingDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                return staging
            },
            dispose: { url in try Self.moveToTrash(url, trash) })
        return (installer, staging, trash)
    }

    /// Like the Finder's Trash, a second item of the same name gets a new name rather than failing.
    static func moveToTrash(_ url: URL, _ trash: URL) throws -> URL? {
        var target = trash.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    @Test func installsACopyWithoutQuarantine() throws {
        let folder = try Folder()
        let source = try Self.makeBundle(in: try folder.folder("Downloads"), name: "Restorey 2.app", marker: "new")
        let applications = try folder.folder("Applications")
        let destination = AppMove.destination(productName: "RestoreyDev", applications: applications)
        let (installer, staging, _) = try Self.installer(in: folder)
        try installer.install(source, at: destination, replacing: false)

        #expect(try Self.marker(destination) == "new")
        #expect(!Self.isQuarantined(destination.path))
        #expect(!Self.isQuarantined(destination.appendingPathComponent("Contents/MacOS/RestoreyDev").path))
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("Contents/Current").path)
        #expect(link.hasSuffix("Contents/MacOS"))
        // The source is left as it was; nothing else is left in Applications; the staging folder is gone.
        #expect(Self.isQuarantined(source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["RestoreyDev.app"])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func replacingSendsTheOldCopyToTheTrash() throws {
        let folder = try Folder()
        let source = try Self.makeBundle(in: try folder.folder("Downloads"), marker: "new")
        let old = try Self.makeBundle(in: try folder.folder("Applications"), marker: "old")
        let (installer, _, trash) = try Self.installer(in: folder)

        #expect(throws: AppMoveError.destinationExists) {
            try installer.install(source, at: old, replacing: false)
        }
        #expect(try Self.marker(old) == "old")

        try installer.install(source, at: old, replacing: true)
        #expect(try Self.marker(old) == "new")
        #expect(!Self.isQuarantined(old.path))
        #expect(try Self.marker(trash.appendingPathComponent("RestoreyDev.app")) == "old")
    }

    /// A source bundle with a folder nobody can read. APFS clones ignore a file's own mode, but copying can't
    /// list an unreadable folder, so `copyItem` fails partway, after it has started writing the copy.
    static func makeUnreadableBundle(in folder: URL) throws -> (bundle: URL, restore: () -> Void) {
        let bundle = try makeBundle(in: folder, marker: "new")
        let locked = bundle.appendingPathComponent("Contents/Resources/Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("file.dat"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        return (bundle, { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) })
    }

    @Test func aCopyThatFailsPartwayLeavesNothingBehindAndBlamesTheCopy() throws {
        let folder = try Folder()
        let (source, restore) = try Self.makeUnreadableBundle(in: try folder.folder("Downloads"))
        defer { restore() }
        let applications = try folder.folder("Applications")
        let destination = AppMove.destination(productName: "RestoreyDev", applications: applications)
        let (installer, staging, _) = try Self.installer(in: folder)

        #expect(throws: AppMoveError.unreadableCopy) { try installer.install(source, at: destination, replacing: false) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(AppMoveError.unreadableCopy.description == AppMove.unreadableCopy)
        #expect(!AppMove.unreadableCopy.contains("write to the Applications"))
    }

    @Test func aFailedReplaceKeepsTheOldCopy() throws {
        let folder = try Folder()
        let (source, restore) = try Self.makeUnreadableBundle(in: try folder.folder("Downloads"))
        defer { restore() }
        let old = try Self.makeBundle(in: try folder.folder("Applications"), marker: "old")
        let (installer, _, trash) = try Self.installer(in: folder)

        #expect(throws: AppMoveError.unreadableCopy) { try installer.install(source, at: old, replacing: true) }
        #expect(try Self.marker(old) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    @Test func aReadOnlyApplicationsFolderIsStillAWriteRefusal() throws {
        let folder = try Folder()
        let source = try Self.makeBundle(in: try folder.folder("Downloads"), marker: "new")
        let applications = try folder.folder("Applications")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }
        let destination = AppMove.destination(productName: "RestoreyDev", applications: applications)
        let (installer, _, _) = try Self.installer(in: folder)
        do {
            try installer.install(source, at: destination, replacing: false)
            Issue.record("installed into a read-only folder")
        } catch {
            #expect(AppMove.error(from: error) == .refused(.noPermission))
        }
    }

    @Test func sameItemSeesThroughLinksAndSpelling() throws {
        let folder = try Folder()
        let applications = try folder.folder("Applications")
        let bundle = try Self.makeBundle(in: applications, marker: "x")
        let link = folder.url.appendingPathComponent("AppsLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: applications)
        #expect(AppMove.isSameItem(link.appendingPathComponent("RestoreyDev.app"), bundle))
        #expect(AppMove.isSameItem(URL(fileURLWithPath: applications.path + "/./RestoreyDev.app"), bundle))
        #expect(AppMove.isSameItem(applications.appendingPathComponent("restoreydev.app"), bundle))
        #expect(!AppMove.isSameItem(folder.url.appendingPathComponent("Other.app"), bundle))
    }
}

// MARK: The runner's re-check

private final class FakeProbe: AppMoveProbe {
    let registered: Bool
    let writable: Bool
    init(registered: Bool = false, writable: Bool = true) {
        self.registered = registered
        self.writable = writable
    }
    func agentRegistered() async -> Bool { registered }
    func destinationState(_ url: URL) -> AppMoveDestinationState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        return .present(bundleID: Bundle(url: url)?.bundleIdentifier ?? "com.jaydenkerr.restorey.dev")
    }
    func isWritable(_ directory: URL) -> Bool { writable }
}

@Suite struct AppMoveRunnerTests {
    private static let bundleID = "com.jaydenkerr.restorey.dev"

    private static func runner(
        _ probe: FakeProbe, in folder: AppMoveTests.Folder
    ) throws -> (AppMoveRunner<FakeProbe>, trash: URL) {
        let (installer, _, trash) = try AppMoveTests.installer(in: folder)
        let runner = AppMoveRunner(
            probe: probe, installer: installer, trash: { url in try AppMoveTests.moveToTrash(url, trash) })
        return (runner, trash)
    }

    @Test func movesAndTrashesTheCopyItRanFrom() async throws {
        let folder = try AppMoveTests.Folder()
        let source = try AppMoveTests.makeBundle(in: try folder.folder("Downloads"), name: "Restorey 2.app", marker: "new")
        let destination = AppMove.destination(productName: "RestoreyDev", applications: try folder.folder("Applications"))
        let (runner, trash) = try Self.runner(FakeProbe(), in: folder)

        try await runner.run(source: source, destination: destination, bundleID: Self.bundleID, copyToTrash: source)
        #expect(try AppMoveTests.marker(destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Restorey 2.app").path))
    }

    @Test func refusesAtMoveTimeWhenAnAgentHasBeenRegisteredSince() async throws {
        let folder = try AppMoveTests.Folder()
        let source = try AppMoveTests.makeBundle(in: try folder.folder("Downloads"), marker: "new")
        let destination = AppMove.destination(productName: "RestoreyDev", applications: try folder.folder("Applications"))
        let (runner, _) = try Self.runner(FakeProbe(registered: true), in: folder)

        await #expect(throws: AppMoveError.refused(.agentRegistered)) {
            try await runner.run(source: source, destination: destination, bundleID: Self.bundleID, copyToTrash: source)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func refusesAtMoveTimeWhenApplicationsIsNotWritable() async throws {
        let folder = try AppMoveTests.Folder()
        let source = try AppMoveTests.makeBundle(in: try folder.folder("Downloads"), marker: "new")
        let destination = AppMove.destination(productName: "RestoreyDev", applications: try folder.folder("Applications"))
        let (runner, _) = try Self.runner(FakeProbe(writable: false), in: folder)

        await #expect(throws: AppMoveError.refused(.noPermission)) {
            try await runner.run(source: source, destination: destination, bundleID: Self.bundleID, copyToTrash: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aTranslocatedCopyWhoseOriginalIsTheDestinationIsNotTrashed() async throws {
        // A quarantined copy unzipped straight into Applications runs translocated; its original is the
        // destination, so after the replace the copy to trash is the new copy itself.
        let folder = try AppMoveTests.Folder()
        let mount = try AppMoveTests.makeBundle(in: try folder.folder("AppTranslocation"), marker: "new")
        let applications = try folder.folder("Applications")
        let destination = try AppMoveTests.makeBundle(in: applications, marker: "old")
        let link = folder.url.appendingPathComponent("AppsLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: applications)
        let original = link.appendingPathComponent("RestoreyDev.app")
        let (runner, trash) = try Self.runner(FakeProbe(), in: folder)

        try await runner.run(source: mount, destination: destination, bundleID: Self.bundleID, copyToTrash: original)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try AppMoveTests.marker(destination) == "new")
        // Only the old copy went to the Trash.
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path) == ["RestoreyDev.app"])
        #expect(try AppMoveTests.marker(trash.appendingPathComponent("RestoreyDev.app")) == "old")
    }

    @Test func replacesThisRestoreyAndTrashesTheOldCopy() async throws {
        let folder = try AppMoveTests.Folder()
        let source = try AppMoveTests.makeBundle(in: try folder.folder("Downloads"), marker: "new")
        let destination = try AppMoveTests.makeBundle(in: try folder.folder("Applications"), marker: "old")
        let (runner, trash) = try Self.runner(FakeProbe(), in: folder)

        try await runner.run(source: source, destination: destination, bundleID: Self.bundleID, copyToTrash: nil)
        #expect(try AppMoveTests.marker(destination) == "new")
        #expect(try AppMoveTests.marker(trash.appendingPathComponent("RestoreyDev.app")) == "old")
    }
}
