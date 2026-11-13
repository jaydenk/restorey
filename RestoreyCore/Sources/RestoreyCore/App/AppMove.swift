import Darwin
import Foundation

// Setup's "Move to Applications" screen (UI design §4): the app copies itself into /Applications and relaunches
// from there. These are its decisions and its file work; the app's `AppMover` supplies what it reads from the
// system (`AppMoveProbe`) and adds the relaunch.

/// Why the move won't go ahead.
public enum AppMoveRefusal: Sendable, Equatable {
    /// An agent of this identity is registered, so a backup may be running: the screen only works before any
    /// agent is (UI design §4), whatever copy it belongs to.
    case agentRegistered
    /// The destination holds an app that isn't this Restorey (another bundle identifier, or none).
    case otherApp
    /// This user can't write to /Applications. Restorey never asks for an administrator password for it.
    case noPermission

    public var sentence: String {
        switch self {
        case .agentRegistered: AppMove.refusal
        case .otherApp: AppMove.otherApp
        case .noPermission: AppMove.noPermission
        }
    }
}

/// What the move may do, given the agent's registration and what `/Applications` already holds.
public enum AppMoveDecision: Sendable, Equatable {
    /// Nothing is at the destination.
    case move
    /// This Restorey is at the destination and no agent is registered: the screen offers to replace it.
    case replace
    case refuse(AppMoveRefusal)
}

public enum AppMoveError: Error, Equatable, CustomStringConvertible {
    case refused(AppMoveRefusal)
    /// Something appeared at the destination after the screen decided there was nothing there.
    case destinationExists
    case failed(String)

    public var description: String {
        switch self {
        case .refused(let refusal): refusal.sentence
        case .destinationExists: "A copy of Restorey appeared in Applications while this screen was open. Try again."
        case .failed(let detail): "Restorey couldn't move itself to Applications (\(detail))."
        }
    }
}

/// What is at a path, as far as the move cares.
public enum AppMoveDestinationState: Sendable, Equatable {
    case absent
    /// Something is there; its bundle identifier, nil when it isn't a readable bundle.
    case present(bundleID: String?)
}

/// What the move reads from the system, so its decision (and the re-check inside `AppMoveRunner.run`) can be
/// tested with fakes.
public protocol AppMoveProbe: Sendable {
    /// Whether any agent of this identity is registered.
    func agentRegistered() async -> Bool
    func destinationState(_ url: URL) -> AppMoveDestinationState
    func isWritable(_ directory: URL) -> Bool
}

public enum AppMove {
    public static let explanation =
        "Restorey runs from the Applications folder. It moves itself there and opens again."
    public static let replaceQuestion = "Applications already has a copy of Restorey. Replace it with this one?"
    /// The UI design's rule: with an agent registered, nothing is replaced from here.
    public static let refusal =
        "Restorey is already set up on this Mac, with its background agent running from the copy in Applications. "
        + "Quit Restorey, then replace that copy by hand: drag this one into Applications in Finder."
    public static let otherApp =
        "Applications already has an app with this name that isn't this Restorey. Move or rename it in Finder, "
        + "then try again."
    public static let noPermission =
        "Restorey can't write to the Applications folder. Drag it into Applications in Finder instead."

    public static let quarantineAttribute = "com.apple.quarantine"

    /// The build's own bundle name (`CFBundleName`, the product name), never the name the copy was saved under,
    /// so "Restorey 2.app" from a second download lands as `Restorey.app`.
    public static func destination(productName: String, applications: URL) -> URL {
        applications.appendingPathComponent(productName + ".app", isDirectory: true)
    }

    public static func decision(
        agentRegistered: Bool, destination: AppMoveDestinationState, bundleID: String, applicationsWritable: Bool
    ) -> AppMoveDecision {
        if agentRegistered { return .refuse(.agentRegistered) }
        if case .present(let present) = destination, present != bundleID { return .refuse(.otherApp) }
        if !applicationsWritable { return .refuse(.noPermission) }
        return destination == .absent ? .move : .replace
    }

    /// Reads everything the decision needs from `probe`.
    public static func decide(
        probe: some AppMoveProbe, destination: URL, bundleID: String
    ) async -> AppMoveDecision {
        let registered = await probe.agentRegistered()
        return decision(
            agentRegistered: registered, destination: probe.destinationState(destination), bundleID: bundleID,
            applicationsWritable: probe.isWritable(destination.deletingLastPathComponent()))
    }

    /// The copy to send to the Trash after the move: the bundle itself, or for a translocated launch the original
    /// it was translocated from (nil when that can't be found: the read-only mount is never the one to trash).
    public static func copyToTrash(bundleURL: URL, translocated: Bool, original: URL?) -> URL? {
        translocated ? original : bundleURL
    }

    /// A file-system error as the screen reports it: a permission refusal gets its own sentence.
    public static func error(from error: any Error) -> AppMoveError {
        if let moveError = error as? AppMoveError { return moveError }
        let ns = error as NSError
        let denied = [Int(EACCES), Int(EPERM)]
        if ns.domain == NSCocoaErrorDomain,
            [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code)
        {
            return .refused(.noPermission)
        }
        if ns.domain == NSPOSIXErrorDomain, denied.contains(ns.code) { return .refused(.noPermission) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain, denied.contains(underlying.code)
        {
            return .refused(.noPermission)
        }
        return .failed(ns.localizedDescription)
    }
}

/// Copies an app bundle into place. Only the file work, so tests run it on temporary folders.
public struct AppInstaller: Sendable {
    /// A folder to stage the copy in, on the same volume as the destination; removed afterwards.
    private let stagingDirectory: @Sendable (URL) throws -> URL
    /// Puts a replaced copy somewhere recoverable and returns where, or nil if it can't be told.
    private let dispose: @Sendable (URL) throws -> URL?

    public init(
        stagingDirectory: @escaping @Sendable (URL) throws -> URL = { try AppInstaller.replacementDirectory(for: $0) },
        dispose: @escaping @Sendable (URL) throws -> URL? = { try AppInstaller.trash($0) }
    ) {
        self.stagingDirectory = stagingDirectory
        self.dispose = dispose
    }

    public static func replacementDirectory(for destination: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
    }

    public static func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Copies `source` to `destination` through a staging copy, so a half-made bundle is never at `destination`,
    /// and removes `com.apple.quarantine` from the copy. An existing destination goes to the Trash first when
    /// `replacing` (and comes back if the copy then can't be put in place), and is an error otherwise.
    public func install(_ source: URL, at destination: URL, replacing: Bool) throws {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: destination.path)
        if exists, !replacing { throw AppMoveError.destinationExists }
        let staging = try stagingDirectory(destination)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: source, to: staged)
        try Self.removeQuarantine(under: staged)
        let disposed: URL? = if exists { try dispose(destination) } else { nil }
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            if let disposed { try? fileManager.moveItem(at: disposed, to: destination) }
            throw error
        }
    }

    /// Removes the quarantine attribute from `root` and everything under it, without following links, so
    /// Gatekeeper doesn't translocate or question the moved copy.
    public static func removeQuarantine(under root: URL) throws {
        var paths = [root.path]
        if let walk = FileManager.default.enumerator(atPath: root.path) {
            while let relative = walk.nextObject() as? String {
                paths.append(root.appendingPathComponent(relative).path)
            }
        }
        for path in paths {
            guard removexattr(path, AppMove.quarantineAttribute, XATTR_NOFOLLOW) != 0 else { continue }
            let code = errno
            if code == ENOATTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
    }
}

/// The move itself: decides again (the screen may be stale), installs, and sends the old copy to the Trash.
/// The app opens the moved copy afterwards.
public struct AppMoveRunner<Probe: AppMoveProbe>: Sendable {
    let probe: Probe
    let installer: AppInstaller
    let trash: @Sendable (URL) throws -> URL?

    public init(
        probe: Probe, installer: AppInstaller = AppInstaller(),
        trash: @escaping @Sendable (URL) throws -> URL? = { try AppInstaller.trash($0) }
    ) {
        self.probe = probe
        self.installer = installer
        self.trash = trash
    }

    /// Throws `AppMoveError`. `copyToTrash` is the copy the app ran from (`AppMove.copyToTrash`); a failure to
    /// trash it (a read-only disk image) is ignored.
    public func run(source: URL, destination: URL, bundleID: String, copyToTrash: URL?) async throws {
        let decision = await AppMove.decide(probe: probe, destination: destination, bundleID: bundleID)
        if case .refuse(let refusal) = decision { throw AppMoveError.refused(refusal) }
        let installer = installer
        do {
            try await Task.detached {
                try installer.install(source, at: destination, replacing: decision == .replace)
            }.value
        } catch {
            throw AppMove.error(from: error)
        }
        if let copyToTrash { _ = try? trash(copyToTrash) }
    }
}
