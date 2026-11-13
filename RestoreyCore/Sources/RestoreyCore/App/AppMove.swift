import Darwin
import Foundation

// Setup's "Move to Applications" screen (UI design §4): the app copies itself into /Applications and relaunches
// from there. These are its decisions and its file work; the app's `AppMover` adds the relaunch.

/// What the move may do, given what `/Applications` already holds.
public enum AppMoveDecision: Sendable, Equatable {
    /// Nothing is at the destination.
    case move
    /// A copy is there and its agent isn't registered: the screen offers to replace it.
    case replace
    /// A copy is there and its agent is registered, so it may be running a backup: the user quits it and
    /// replaces it by hand.
    case refuse
}

public enum AppMoveError: Error, Equatable, CustomStringConvertible {
    /// The copy in /Applications has its agent registered (`AppMoveDecision.refuse`).
    case refused
    /// Something appeared at the destination after the screen decided there was nothing there.
    case destinationExists
    /// This user can't write to /Applications. Restorey never asks for an administrator password for it.
    case noPermission
    case failed(String)

    public var description: String {
        switch self {
        case .refused: AppMove.refusal
        case .destinationExists: "A copy of Restorey appeared in Applications while this screen was open. Try again."
        case .noPermission: AppMove.noPermission
        case .failed(let detail): "Restorey couldn't move itself to Applications (\(detail))."
        }
    }
}

public enum AppMove {
    public static let explanation =
        "Restorey runs from the Applications folder. It moves itself there and opens again."
    public static let replaceQuestion = "Applications already has a copy of Restorey. Replace it with this one?"
    /// The UI design's rule: a copy whose agent is registered is never replaced from here.
    public static let refusal =
        "Applications already has a copy of Restorey with its background agent set up. Quit Restorey, then replace "
        + "that copy by hand: drag this one into Applications in Finder."
    public static let noPermission =
        "Restorey can't write to the Applications folder. Drag it into Applications in Finder instead."

    public static let quarantineAttribute = "com.apple.quarantine"

    /// `<applications>/<the bundle's name>`. A translocated bundle keeps its original name.
    public static func destination(for source: URL, applications: URL) -> URL {
        applications.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    }

    public static func decision(destinationExists: Bool, destinationAgentRegistered: Bool) -> AppMoveDecision {
        guard destinationExists else { return .move }
        return destinationAgentRegistered ? .refuse : .replace
    }

    /// A file-system error as the screen reports it: a permission refusal gets its own sentence.
    public static func error(from error: any Error) -> AppMoveError {
        if let moveError = error as? AppMoveError { return moveError }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
            [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code)
        {
            return .noPermission
        }
        if ns.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(ns.code) { return .noPermission }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(underlying.code)
        {
            return .noPermission
        }
        return .failed(ns.localizedDescription)
    }
}

/// Copies an app bundle into place. Only the file work, so tests run it on temporary folders.
public struct AppInstaller {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies `source` to `destination`, through a staging copy on the destination's volume so a half-made
    /// bundle is never at `destination`, and removes `com.apple.quarantine` from the copy. An existing
    /// destination is swapped out atomically when `replacing`, and is an error otherwise.
    public func install(_ source: URL, at destination: URL, replacing: Bool) throws {
        let exists = fileManager.fileExists(atPath: destination.path)
        if exists, !replacing { throw AppMoveError.destinationExists }
        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: source, to: staged)
        try Self.removeQuarantine(under: staged)
        if exists {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
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
