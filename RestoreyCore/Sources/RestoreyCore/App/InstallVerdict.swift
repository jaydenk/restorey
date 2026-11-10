import Foundation

/// Where the running app is, as far as the agent is concerned (spec §8 "Must live in /Applications").
/// Only `.ok` may touch the agent: a copy run from a DMG, from `~/Downloads` or from a translocated path
/// can re-point the agent's registration just by reading `SMAppService.status` (spike phase B).
public enum InstallVerdict: Sendable, Equatable {
    case ok
    /// Gatekeeper is running the app from a randomised, read-only translocation mount.
    case translocated
    /// Not inside `/Applications`.
    case notInApplications(URL)
}

/// `.ok` only for a bundle inside `/Applications` (a subfolder such as `/Applications/Utilities` is
/// fine) that isn't translocated. `isTranslocated` is the Security framework's answer; a path through
/// an `AppTranslocation` folder counts as translocated too, whatever it says.
public func installVerdict(bundleURL: URL, isTranslocated: Bool) -> InstallVerdict {
    let components = bundleURL.standardizedFileURL.pathComponents
    if isTranslocated || components.contains("AppTranslocation") { return .translocated }
    // "/", "Applications", optional folders, then the bundle, with no other bundle around it.
    guard components.count >= 3, components[0] == "/",
          components[1].caseInsensitiveCompare("Applications") == .orderedSame,
          let bundle = components.last, bundle.lowercased().hasSuffix(".app"),
          !components.dropFirst(2).dropLast().contains(where: { $0.lowercased().hasSuffix(".app") })
    else { return .notInApplications(bundleURL) }
    return .ok
}
