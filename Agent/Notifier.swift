import AgentCore
import Foundation
import UserNotifications

/// The agent's notifications, through `UNUserNotificationCenter`. The agent needs its own permission:
/// the app's doesn't cover it, and posting without one reports success while nothing appears
/// (docs/spike-findings.md, H3b). So onboarding asks from the agent, over XPC, and `AgentState` checks
/// `authorisationStatus()` before posting and raises `notificationsOff` when it isn't granted.
///
/// What each notification says is decided in AgentCore (`AlertContent`), where it is tested.
struct Notifier: AlertNotifying {
    private var center: UNUserNotificationCenter { .current() }

    /// Shows the system prompt the first time; afterwards it returns the user's answer without asking.
    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func authorisationStatus() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: true
        case .denied: false
        case .notDetermined: nil
        @unknown default: nil
        }
    }

    func post(_ alert: AlertContent) async throws {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.threadIdentifier
        content.sound = .default
        // The same identifier replaces the banner a re-notification follows.
        try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
    }
}
