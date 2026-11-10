import Foundation
import RestoreyCore

/// Proof that this copy of the app is the installed one: inside /Applications and not translocated.
///
/// `AgentRegistration`, `AgentConnection` and `AgentSupervisor` can only be made from one of these, and
/// only `InstallLocation.check` can make one (its initialiser is private to this file). So a copy run from
/// a DMG, `~/Downloads` or a translocation mount can't reach any code that touches the agent: no XPC, no
/// `register`, `unregister` or even a `SMAppService.status` read, which on its own re-points the agent's
/// registration at the copy (spike phase B, spec §8 "Must live in /Applications").
struct InstalledCopy: Sendable {
    let bundleURL: URL

    fileprivate init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    /// `<bundle>/Contents/Helpers/`: where the agent binary must be.
    var helpersPrefix: String {
        bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true).path + "/"
    }
}

enum InstallLocation {
    enum Outcome {
        case installed(InstalledCopy)
        case refused(InstallVerdict)
    }

    static func check(bundle: Bundle = .main) -> Outcome {
        let url = bundle.bundleURL
        let verdict = installVerdict(bundleURL: url, isTranslocated: isTranslocated(url))
        guard verdict == .ok else { return .refused(verdict) }
        return .installed(InstalledCopy(bundleURL: url))
    }

    private typealias IsTranslocatedURL = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool

    /// `SecTranslocateIsTranslocatedURL`, loaded with `dlsym` as LetsMove does: it is exported by
    /// Security.framework but not declared in its headers. False when the symbol or the call fails;
    /// `installVerdict` also refuses any path through an `AppTranslocation` folder, so the gate never
    /// rests on this alone.
    private static func isTranslocated(_ url: URL) -> Bool {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL")
        else { return false }
        let function = unsafeBitCast(symbol, to: IsTranslocatedURL.self)
        var translocated = false
        guard function(url as CFURL, &translocated, nil) else { return false }
        return translocated
    }
}
