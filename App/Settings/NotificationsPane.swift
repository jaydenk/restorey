import AppKit
import RestoreyCore
import SwiftUI

/// Settings → Notifications (visual polish §1): whether macOS lets Restorey’s background process post notifications,
/// with the fix (ask, or System Settings). The words are `SettingsGeneral`'s. Read again whenever Restorey comes back
/// to the front, since the user may have changed it in System Settings.
struct NotificationsPane: View {
    let supervisor: AgentSupervisor
    /// The permission question is up.
    @State private var asking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Notifications") {
                    LineView(line: SettingsGeneral.notifications(hello: supervisor.lastHello), busy: asking) { action in
                        guard !asking else { return }
                        asking = true
                        Task {
                            await GeneralActionRunner.run(action, supervisor: supervisor)
                            asking = false
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await supervisor.refreshHello() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await supervisor.refreshHello() }
        }
    }
}
