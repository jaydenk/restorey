import Foundation
import Testing
@testable import RestoreyCore

/// Settings → Network (UI design §6.3, product spec §5.5): the Mac-wide rules as an edit with Save and Revert, the
/// Wi-Fi list's additions, and when adding a name asks the agent for Location permission.
struct NetworkEditTests {
    private static let saved = NetworkSettings(uploadLimitKiB: 5120, skipOnConstrainedNetwork: true, skippedWiFiNames: ["Cafe"])

    // MARK: Changes

    @Test func aFreshEditShowsTheSavedSettingsAndIsUnchanged() {
        let edit = NetworkEdit(settings: Self.saved)
        #expect(edit.fields.uploadLimit == "5")
        #expect(edit.fields.skipOnConstrainedNetwork)
        #expect(edit.fields.wiFiNames == ["Cafe"])
        #expect(!edit.isDirty)
        #expect(edit.problem == nil)
        #expect(edit.request() == .success(Self.saved))
    }

    @Test func noLimitIsAnEmptyField() {
        #expect(NetworkEdit(settings: .defaults).fields.uploadLimit == "")
    }

    @Test func eachFieldIsSavedAsTyped() {
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.uploadLimit = " 1.5 "
        edit.fields.skipOnConstrainedNetwork = false
        let added = edit.add(name: "  Phone hotspot ")
        #expect(added)
        #expect(edit.isDirty)
        #expect(edit.request() == .success(NetworkSettings(
            uploadLimitKiB: 1536, skipOnConstrainedNetwork: false, skippedWiFiNames: ["Cafe", "Phone hotspot"])))
    }

    @Test func clearingTheLimitSavesNone() throws {
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.uploadLimit = ""
        #expect(try edit.request().get().uploadLimitKiB == nil)
    }

    /// A limit the field can only show rounded (3 KiB/s is "0"), left alone, keeps the agent's exact value.
    @Test func anUntouchedLimitKeepsTheSavedValueExactly() throws {
        let odd = NetworkSettings(uploadLimitKiB: 3, skipOnConstrainedNetwork: true, skippedWiFiNames: [])
        var edit = NetworkEdit(settings: odd)
        edit.fields.skipOnConstrainedNetwork = false
        #expect(try edit.request().get().uploadLimitKiB == 3)
    }

    @Test func revertGoesBackToTheSavedSettings() {
        var edit = NetworkEdit(settings: Self.saved)
        edit.fields.uploadLimit = "9"
        edit.remove(name: "Cafe")
        edit.revert()
        #expect(!edit.isDirty)
        #expect(edit.fields == NetworkEdit.Fields(settings: Self.saved))
    }

    @Test func aSaveStartsAgainFromWhatTheAgentSaved() {
        var edit = NetworkEdit(settings: Self.saved)
        _ = edit.add(name: "Home ")
        edit.didSave(NetworkSettings(uploadLimitKiB: 5120, skipOnConstrainedNetwork: true, skippedWiFiNames: ["Cafe", "Home"]))
        #expect(!edit.isDirty)
        #expect(edit.fields.wiFiNames == ["Cafe", "Home"])
    }

    /// The agent's copy changed (a save from another window): an untouched form follows it; edits are kept.
    @Test func rebaseFollowsTheAgentOnlyWhileUntouched() throws {
        let newer = NetworkSettings(uploadLimitKiB: nil, skipOnConstrainedNetwork: false, skippedWiFiNames: [])
        var untouched = NetworkEdit(settings: Self.saved)
        untouched.rebase(on: newer)
        #expect(untouched.fields == NetworkEdit.Fields(settings: newer))
        #expect(!untouched.isDirty)

        var edited = NetworkEdit(settings: Self.saved)
        edited.fields.uploadLimit = "2"
        edited.rebase(on: newer)
        #expect(edited.fields.uploadLimit == "2")
        #expect(edited.saved == newer)
        // What the form shows follows the agent too, except the field being edited.
        #expect(!edited.fields.skipOnConstrainedNetwork)
        #expect(edited.fields.wiFiNames == [])
        // Fields the user didn't touch keep the agent's newer values.
        #expect(try edited.request().get() == NetworkSettings(
            uploadLimitKiB: 2048, skipOnConstrainedNetwork: false, skippedWiFiNames: []))
    }

    // MARK: Problems

    @Test func aBadLimitIsTheProblemAndBlocksTheSave() {
        var edit = NetworkEdit(settings: .defaults)
        edit.fields.uploadLimit = "fast"
        #expect(edit.uploadLimitProblem == "Enter the limit as a number of MB/s, such as 5 or 1.5.")
        #expect(edit.problem == edit.uploadLimitProblem)
        #expect(throws: FormValidation.Problem.self) { try edit.request().get() }
        edit.fields.uploadLimit = "0"
        #expect(edit.problem == "The upload limit must be more than 0 MB/s. Leave it empty for no limit.")
    }

    /// The agent refuses these too (`NetworkSettings.validationErrors`); the form says so first, with a full stop.
    @Test func aListTheAgentWouldRefuseIsAProblem() {
        var edit = NetworkEdit(settings: .defaults)
        edit.fields.wiFiNames = ["Cafe", "cafe "]
        #expect(edit.problem == "The Wi-Fi network “cafe” is in the list more than once.")
    }

    @Test func aNameToAddMustBeNewAndOnOneLine() {
        var edit = NetworkEdit(settings: Self.saved)
        #expect(edit.newNameProblem("   ") == "Enter the Wi-Fi network's name.")
        #expect(edit.newNameProblem(" CAFE") == "“CAFE” is already in the list.")
        #expect(edit.newNameProblem("Two\nlines") == "A Wi-Fi network's name is on one line.")
        #expect(edit.newNameProblem("Home") == nil)
        let added = edit.add(name: "cafe")
        #expect(!added)
        #expect(edit.fields.wiFiNames == ["Cafe"])
        #expect(!edit.isDirty)
    }

    /// Wi-Fi names longer than 32 bytes don't exist (IEEE 802.11 SSIDs are at most 32 octets).
    @Test func aNameLongerThanAnSSIDIsRefused() {
        let edit = NetworkEdit(settings: .defaults)
        #expect(edit.newNameProblem(String(repeating: "a", count: 32)) == nil)
        #expect(edit.newNameProblem(String(repeating: "a", count: 33))
            == "A Wi-Fi network's name is at most 32 bytes long.")
        // "é" is two bytes in UTF-8.
        #expect(edit.newNameProblem(String(repeating: "é", count: 17)) != nil)
    }

    @Test func removingANameIsAnEdit() throws {
        var edit = NetworkEdit(settings: Self.saved)
        edit.remove(name: "Cafe")
        #expect(edit.isDirty)
        #expect(try edit.request().get().skippedWiFiNames == [])
    }

    // MARK: Location permission (UI design §6.3: asked only when the user first adds a network)

    private static func hello(authorised: Bool?, servicesEnabled: Bool?) -> HelloReply {
        HelloReply(
            agentVersion: "0.1.0", agentBuild: "1", executablePath: "/x", draining: false, notificationsAuthorised: true,
            locationAuthorised: authorised, locationServicesEnabled: servicesEnabled)
    }

    @Test func accessComesFromTheAgentsHello() {
        #expect(WiFiNameAccess(hello: nil) == .checking)
        #expect(WiFiNameAccess(hello: Self.hello(authorised: nil, servicesEnabled: true)) == .notAsked)
        #expect(WiFiNameAccess(hello: Self.hello(authorised: true, servicesEnabled: true)) == .allowed)
        #expect(WiFiNameAccess(hello: Self.hello(authorised: false, servicesEnabled: true)) == .refused)
        // An agent older than this field says nothing about Location Services: its authorisation decides.
        #expect(WiFiNameAccess(hello: Self.hello(authorised: true, servicesEnabled: nil)) == .allowed)
    }

    /// Location Services switched off for the whole Mac wins over everything: no app can see the Wi-Fi name then,
    /// and macOS may still report the agent as never asked.
    @Test func locationServicesOffForTheMacWins() {
        for authorised in [true, false, nil] as [Bool?] {
            #expect(WiFiNameAccess(hello: Self.hello(authorised: authorised, servicesEnabled: false)) == .servicesOff)
        }
    }

    @Test func accessAfterTheAgentsAnswer() {
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: true, status: "authorisedAlways")) == .allowed)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: false, status: "denied")) == .refused)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: false, status: "restricted")) == .refused)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(authorised: false, status: "notDetermined")) == .notAsked)
        #expect(WiFiNameAccess(reply: LocationPermissionReply(
            authorised: false, status: "notDetermined", servicesEnabled: false)) == .servicesOff)
    }

    /// The "ask now?" decision: only adding a name while the agent has never been asked asks; a decided answer is
    /// never asked again (macOS wouldn't show the prompt), and with Location Services off nothing asks at all.
    @Test func addingANameAsksOnlyWhenNeverAsked() {
        #expect(WiFiNameAccess.notAsked.addStep == .askFirst)
        // Before the first hello the agent decides: it answers at once if the user already has.
        #expect(WiFiNameAccess.checking.addStep == .askFirst)
        #expect(WiFiNameAccess.allowed.addStep == .add)
        #expect(WiFiNameAccess.refused.addStep == .blocked)
        #expect(WiFiNameAccess.servicesOff.addStep == .blocked)
    }

    @Test func whatTheListSaysForEachAccess() {
        #expect(WiFiNameAccess.allowed.note(listed: 1) == nil)
        #expect(WiFiNameAccess.checking.note(listed: 0) == nil)
        #expect(WiFiNameAccess.notAsked.note(listed: 0)
            == "Adding a network asks for Location permission: macOS shows the Wi-Fi network's name only to apps "
            + "allowed to use Location.")
        #expect(WiFiNameAccess.refused.note(listed: 0) == "Restorey needs Location permission to see Wi-Fi names.")
        #expect(WiFiNameAccess.refused.note(listed: 2)
            == "Restorey needs Location permission to see Wi-Fi names. Until then, backups aren't skipped on these networks.")
        #expect(WiFiNameAccess.servicesOff.note(listed: 0)
            == "Location Services is off for this Mac, so Restorey can't see Wi-Fi names. Turn it on in System Settings "
            + "→ Privacy & Security → Location Services.")
        #expect(WiFiNameAccess.refused.opensSystemSettings)
        #expect(WiFiNameAccess.servicesOff.opensSystemSettings)
        #expect(!WiFiNameAccess.notAsked.opensSystemSettings)
        #expect(!WiFiNameAccess.allowed.opensSystemSettings)
        #expect(WiFiNameAccess.unanswered
            == "There was no answer about Location permission, so the network wasn't added. Add it again to be asked again.")
    }
}
