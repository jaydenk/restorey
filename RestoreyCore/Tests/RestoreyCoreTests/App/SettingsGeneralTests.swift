import Foundation
import Testing
@testable import RestoreyCore

/// Settings → General (UI design §6.1, mockup `v0.1-settings.html`): each line's words and its fix, in the menu's
/// wording where the menu says the same thing.
struct SettingsGeneralTests {
    @Test func fullDiskAccess() {
        #expect(SettingsGeneral.fullDiskAccess(missing: false) == .init("Granted"))
        #expect(SettingsGeneral.fullDiskAccess(missing: nil) == .init("Checking…"))
        #expect(SettingsGeneral.fullDiskAccess(missing: true)
            == .init("Missing — backups would be empty", severity: .error, action: .openFullDiskAccess))
        #expect(GeneralAction.openFullDiskAccess.buttonTitle == "Fix…")
    }

    private static func hello(notifications: Bool?) -> HelloReply {
        HelloReply(
            agentVersion: "0.1.0", agentBuild: "11", executablePath: "/x", draining: false,
            notificationsAuthorised: notifications)
    }

    /// No hello yet is "unknown", not "never asked": only a hello carrying nil says the agent hasn't asked.
    @Test func notifications() {
        #expect(SettingsGeneral.notifications(hello: Self.hello(notifications: true)) == .init("Allowed"))
        #expect(SettingsGeneral.notifications(hello: Self.hello(notifications: false))
            == .init("Off — Restorey can't alert you", severity: .warning, action: .openNotificationSettings))
        #expect(SettingsGeneral.notifications(hello: Self.hello(notifications: nil))
            == .init("Not asked yet", severity: .warning, action: .askForNotifications))
        #expect(SettingsGeneral.notifications(hello: nil) == .init("Checking…"))
        #expect(GeneralAction.openNotificationSettings.buttonTitle == "Turn On…")
        #expect(GeneralAction.askForNotifications.buttonTitle == "Turn On…")
    }

    @Test func theAgentLineCarriesItsVersion() {
        let hello = HelloReply(
            agentVersion: "0.1.0", agentBuild: "11", executablePath: "/x", draining: false, notificationsAuthorised: true)
        #expect(SettingsGeneral.agent(health: .healthy, hello: hello) == .init("Running · 0.1.0 (11)"))
        #expect(SettingsGeneral.agent(health: .healthy, hello: nil) == .init("Running"))
        #expect(SettingsGeneral.agent(health: .checking, hello: nil) == .init("Connecting…"))
        #expect(SettingsGeneral.agent(health: .updating, hello: hello) == .init("Updating · 0.1.0 (11)"))
        #expect(SettingsGeneral.agent(health: .waitingForUpdate, hello: nil) == .init("Updating"))
        #expect(SettingsGeneral.agent(health: .switchedOff, hello: nil)
            == .init("Switched off — no backups will happen", severity: .error, action: .openLoginItems))
        #expect(SettingsGeneral.agent(health: .notRunning(reachable: false), hello: nil)
            == .init("Not running — no backups will happen", severity: .error, action: .restartAgent))
        #expect(SettingsGeneral.agent(health: .damaged, hello: nil)
            == .init("Restorey's installation is damaged — reinstall it from the download", severity: .error))
        #expect(SettingsGeneral.agent(health: .failed("Restorey couldn't register its agent."), hello: nil)
            == .init("Restorey couldn't register its agent.", severity: .error))
        #expect(GeneralAction.restartAgent.buttonTitle == "Restart Agent")
        #expect(GeneralAction.openLoginItems.buttonTitle == "Open Login Items…")
    }

    /// `requiresApproval`: the user switched Restorey off in Login Items, and only they can switch it back on.
    @Test func openAtLogin() {
        #expect(SettingsGeneral.openAtLogin(.enabled) == .init(isOn: true, note: nil))
        #expect(SettingsGeneral.openAtLogin(.notRegistered) == .init(isOn: false, note: nil))
        #expect(SettingsGeneral.openAtLogin(.notFound) == .init(isOn: false, note: nil))
        #expect(SettingsGeneral.openAtLogin(.requiresApproval) == .init(
            isOn: false, note: "Restorey is switched off in System Settings → General → Login Items. Switch it on there."))
    }
}
