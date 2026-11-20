import Foundation
import Security

/// The code signing requirements on Restorey's XPC connections (spec §8). The agent's listeners admit only the
/// app (or, for the helper, the agent itself); the app and the helper client talk only to the agent.
public enum CodeSigning {
    /// The Info.plist key that carries the team ID, set from `DEVELOPMENT_TEAM` by the build.
    public static let teamIDKey = "RestoreyTeamID"

    /// A code requirement for `bundleID` signed by `team` through an Apple-issued certificate. `team` must be a
    /// team ID (`isTeamID`): XPC treats a malformed requirement as a fatal error.
    public static func requirement(bundleID: String, team: String) -> String {
        "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team ID from the bundle's `RestoreyTeamID` Info.plist key, or nil when it is missing or malformed.
    /// The agent starts no listener without one: fail closed.
    public static func teamID(in bundle: Bundle) -> String? {
        validTeamID(bundle.object(forInfoDictionaryKey: teamIDKey))
    }

    /// Internal so tests can inject a dictionary instead of a real bundle.
    static func teamID(infoDictionary: [String: Any]) -> String? {
        validTeamID(infoDictionary[teamIDKey])
    }

    private static func validTeamID(_ value: Any?) -> String? {
        guard let team = value as? String, isTeamID(team) else { return nil }
        return team
    }

    /// Ten upper-case letters and digits, Apple's team ID format.
    static func isTeamID(_ string: String) -> Bool {
        string.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    }
}

/// What the running process's own code signature says.
public enum OwnSignature: Equatable, Sendable {
    /// No signature at all.
    case unsigned
    /// A valid signature, with the team identifier it carries: nil for ad-hoc and linker signatures.
    case signed(team: String?)
    /// The signature couldn't be read or isn't valid: the `OSStatus`.
    case unreadable(Int32)

    /// Reads this process's signature. `SecCodeCopySigningInformation` doesn't validate, so the running code is
    /// checked first (Apple: "you must successfully call SecCodeCheckValidity ... before").
    public static func current() -> OwnSignature {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { return .unreadable(status) }
        status = SecCodeCheckValidity(code, [], nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .unreadable(status) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return .unreadable(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let information = information as? [String: Any] else { return .unreadable(status) }
        return .signed(team: information[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}

/// The check the app puts on its connection to the agent, decided once from its own signature.
public enum AgentPeerCheck: Equatable, Sendable {
    /// The app has no team signature (an unsigned or ad-hoc Debug or CI build), so there is no team to require
    /// of the agent either: the connection is unchecked, so such builds still connect (Review Focus 5).
    case unchecked
    /// The app is signed by its declared team: the agent must be too, with its own bundle ID.
    case required(String)
    /// The signature can't be trusted to name a team (unreadable, malformed, or not the Info.plist team): admit
    /// no agent at all rather than none checked.
    case refuseAll(reason: String)

    /// The requirement string for `NSXPCConnection.setCodeSigningRequirement`, or nil for `.unchecked`.
    /// `never` is the requirement language's constant false.
    public var requirement: String? {
        switch self {
        case .unchecked: nil
        case .required(let requirement): requirement
        case .refuseAll: "never"
        }
    }

    /// `declaredTeam` is the Info.plist team (`CodeSigning.teamID(in:)`). Only the signature says whether the
    /// app is signed: unsigned Debug and CI builds still carry the Info.plist key.
    public static func decide(agentBundleID: String, own: OwnSignature, declaredTeam: String?) -> AgentPeerCheck {
        switch own {
        case .unsigned, .signed(team: nil):
            return .unchecked
        case .unreadable(let status):
            return .refuseAll(reason: "its own code signature couldn't be read (OSStatus \(status))")
        case .signed(team: let team?):
            guard CodeSigning.isTeamID(team) else {
                return .refuseAll(reason: "its signature's team identifier is malformed")
            }
            guard team == declaredTeam else {
                return .refuseAll(reason: "it is signed by team \(team) but its Info.plist declares \(declaredTeam ?? "none")")
            }
            return .required(CodeSigning.requirement(bundleID: agentBundleID, team: team))
        }
    }
}
