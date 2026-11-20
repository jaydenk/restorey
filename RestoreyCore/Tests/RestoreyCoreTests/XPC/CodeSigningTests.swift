import Foundation
import Testing
@testable import RestoreyCore

@Suite struct CodeSigningTests {
    private static let team = "X72LEXP4DY"

    // MARK: The requirement

    @Test func requirementForTheDevAndReleaseBundleIDs() {
        #expect(CodeSigning.requirement(bundleID: "com.jaydenkerr.restorey.dev.agent", team: Self.team)
            == "identifier \"com.jaydenkerr.restorey.dev.agent\" and anchor apple generic and certificate leaf[subject.OU] = \"X72LEXP4DY\"")
        #expect(CodeSigning.requirement(bundleID: "com.jaydenkerr.restorey.agent", team: Self.team)
            == "identifier \"com.jaydenkerr.restorey.agent\" and anchor apple generic and certificate leaf[subject.OU] = \"X72LEXP4DY\"")
        #expect(CodeSigning.requirement(bundleID: "com.jaydenkerr.restorey.dev", team: Self.team)
            == "identifier \"com.jaydenkerr.restorey.dev\" and anchor apple generic and certificate leaf[subject.OU] = \"X72LEXP4DY\"")
        #expect(CodeSigning.requirement(bundleID: "com.jaydenkerr.restorey", team: Self.team)
            == "identifier \"com.jaydenkerr.restorey\" and anchor apple generic and certificate leaf[subject.OU] = \"X72LEXP4DY\"")
    }

    /// Every requirement handed to XPC must compile: a malformed one is a fatal error in Swift.
    @Test func requirementsCompile() {
        for string in [
            CodeSigning.requirement(bundleID: "com.jaydenkerr.restorey.dev.agent", team: Self.team),
            AgentPeerCheck.refuseAll(reason: "x").requirement!,
        ] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(string as CFString, [], &requirement) == errSecSuccess, "\(string)")
        }
    }

    // MARK: The team ID from Info.plist

    @Test func teamIDFromInfoPlist() {
        #expect(CodeSigning.teamID(infoDictionary: ["RestoreyTeamID": Self.team]) == Self.team)
    }

    @Test(arguments: [
        [:],
        ["RestoreyTeamID": ""],
        ["RestoreyTeamID": "$(DEVELOPMENT_TEAM)"],
        ["RestoreyTeamID": "x72lexp4dy"],
        ["RestoreyTeamID": "X72LEXP4D"],
        ["RestoreyTeamID": "X72LEXP4DYZ"],
        ["RestoreyTeamID": "X72LEXP4D\""],
        ["RestoreyTeamID": 42],
    ] as [[String: any Sendable]])
    func missingOrMalformedTeamIDIsNil(info: [String: any Sendable]) {
        #expect(CodeSigning.teamID(infoDictionary: info) == nil)
    }

    // MARK: The app's check on its agent connection

    private static let agent = "com.jaydenkerr.restorey.agent"

    @Test func signedByTheDeclaredTeamRequiresTheAgentSignedByIt() {
        let check = AgentPeerCheck.decide(agentBundleID: Self.agent, own: .signed(team: Self.team), declaredTeam: Self.team)
        #expect(check == .required(CodeSigning.requirement(bundleID: Self.agent, team: Self.team)))
        #expect(check.requirement == CodeSigning.requirement(bundleID: Self.agent, team: Self.team))
    }

    /// Unsigned Debug and CI builds still carry the Info.plist team (Local.xcconfig sets `DEVELOPMENT_TEAM`), so
    /// the key alone doesn't mean the app is signed: these connect unchecked (Review Focus 5).
    @Test func unsignedOrAdHocConnectsUnchecked() {
        for own in [OwnSignature.unsigned, .signed(team: nil)] {
            for declared in [Self.team, nil] {
                let check = AgentPeerCheck.decide(agentBundleID: Self.agent, own: own, declaredTeam: declared)
                #expect(check == .unchecked)
                #expect(check.requirement == nil)
            }
        }
    }

    /// A team signature that disagrees with Info.plist, a malformed team, or a signature that can't be read never
    /// drops the check: the connection admits nothing.
    @Test(arguments: [
        (OwnSignature.signed(team: Self.team), nil as String?),
        (OwnSignature.signed(team: Self.team), "ABCDE12345"),
        (OwnSignature.signed(team: "ABCDE12345"), Self.team),
        (OwnSignature.signed(team: "bad\" or always"), "bad\" or always"),
        (OwnSignature.unreadable(-67_050), Self.team),
        (OwnSignature.unreadable(-67_050), nil),
    ])
    func anyOtherSignatureRefusesEveryAgent(own: OwnSignature, declared: String?) {
        let check = AgentPeerCheck.decide(agentBundleID: Self.agent, own: own, declaredTeam: declared)
        guard case .refuseAll = check else {
            Issue.record("expected refuseAll, got \(check)")
            return
        }
        #expect(check.requirement == "never")
    }
}
