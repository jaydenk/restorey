import Foundation

/// A fix Settings → General offers beside a line.
public enum GeneralAction: Sendable, Equatable {
    case openFullDiskAccess
    /// Notifications have never been asked for: the agent asks (it posts them).
    case askForNotifications
    /// Notifications were refused: only System Settings can turn them on.
    case openNotificationSettings
    case restartAgent
    case openLoginItems

    /// The menu's words for the same fixes (`BannerAction.buttonTitle`).
    public var buttonTitle: String {
        switch self {
        case .openFullDiskAccess: BannerAction.openFullDiskAccess.buttonTitle
        case .askForNotifications: "Allow…"
        case .openNotificationSettings: BannerAction.turnOnNotifications.buttonTitle
        case .restartAgent: BannerAction.restartAgent.buttonTitle
        case .openLoginItems: BannerAction.openLoginItems.buttonTitle
        }
    }
}

/// What Settings → General shows (UI design §6.1, mockup `v0.1-settings.html`): notifications and the background
/// agent (Full Disk Access is `FullDiskAccessGuide`'s), each with its fix, and the open-at-login switch. Pure; the pane reads the agent and
/// `SMAppService` and does the fixes.
public enum SettingsGeneral {
    public struct Line: Sendable, Equatable {
        public var value: String
        public var severity: Severity?
        public var action: GeneralAction?

        public init(_ value: String, severity: Severity? = nil, action: GeneralAction? = nil) {
            self.value = value
            self.severity = severity
            self.action = action
        }
    }

    public struct LoginSwitch: Sendable, Equatable {
        public var isOn: Bool
        /// Shown under the switch when the user switched Restorey off in Login Items (`requiresApproval`).
        public var note: String?

        public init(isOn: Bool, note: String?) {
            self.isOn = isOn
            self.note = note
        }
    }

    /// The agent's answer from the notification centre (`HelloReply.notificationsAuthorised`). No hello yet is
    /// unknown; a hello with no answer means the agent has never asked.
    public static func notifications(hello: HelloReply?) -> Line {
        guard let hello else { return Line("Checking…") }
        switch hello.notificationsAuthorised {
        case true?: return Line("Allowed")
        case false?: return Line("Off — Restorey can’t alert you", severity: .warning, action: .openNotificationSettings)
        case nil: return Line("Not asked yet", severity: .warning, action: .askForNotifications)
        }
    }

    /// "Running · 0.1.0 (11)": the supervisor's health and the version from the last hello.
    public static func agent(health: AgentHealthState, hello: HelloReply?) -> Line {
        let version = hello.map { " · \($0.agentVersion) (\($0.agentBuild))" } ?? ""
        switch health {
        case .healthy: return Line("Running" + version)
        case .checking: return Line("Connecting…")
        case .updating, .waitingForUpdate: return Line("Updating" + version)
        case .switchedOff:
            return Line("Switched off — no backups will happen", severity: .error, action: .openLoginItems)
        case .notRunning:
            return Line("Not running — no backups will happen", severity: .error, action: .restartAgent)
        case .waitingForRunningBackup:
            // A restic runs under the agent, so backups are happening (fix round 1).
            return Line("Not answering — a backup is still running", severity: .warning, action: .restartAgent)
        case .damaged:
            return Line("Restorey’s installation is damaged — reinstall it from the download", severity: .error)
        case .signatureUntrusted:
            return Line("Restorey can’t verify its own signature — reinstall it from the download", severity: .error)
        case .failed(let sentence):
            return Line(sentence, severity: .error)
        }
    }

    /// Open at login is on only while `SMAppService.mainApp` is enabled (`loginItemIsEnabled`).
    public static func openAtLogin(_ status: AgentServiceStatus) -> LoginSwitch {
        LoginSwitch(
            isOn: loginItemIsEnabled(status),
            note: status == .requiresApproval
                ? "Restorey is switched off in System Settings → General → Login Items. Switch it on there." : nil)
    }
}
