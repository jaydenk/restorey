import RestoreyCore
import SwiftUI

/// Setup step 1 (mockup step 1, UI design §4): in Applications, Full Disk Access (required, checked by the agent
/// every 2 s while the window can be seen and whenever the app comes back to the front), notifications (optional) and Open at
/// login (on by default, P2-16).
struct PermissionsView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PermissionRow(title: "Restorey is in Applications") { Done() }
            Divider()
            PermissionRow(title: "Full Disk Access") {
                if model.fullDiskAccessGranted {
                    Done()
                } else {
                    Button("Open Settings…") { model.openFullDiskAccessSettings() }
                }
            }
            Divider()
            PermissionRow(title: "Notifications") {
                switch model.notificationsAuthorised {
                case true?: Done()
                case false?: Button("Turn On in Settings…") { model.openNotificationSettings() }
                case nil:
                    Button("Allow…") { Task { await model.requestNotifications() } }
                        .disabled(model.requestingNotifications)
                }
            }
            Divider()
            PermissionRow(title: "Open at login") {
                Toggle("Open at login", isOn: $model.openAtLogin).labelsHidden().toggleStyle(.switch)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Restorey needs Full Disk Access to back up all your files. Granting it quits Restorey. It reopens here and ticks it off.")
                if model.notificationsAuthorised == false {
                    Text("Without notifications, Restorey can't alert you when a backup needs attention.")
                }
                if let error = model.fullDiskAccessError { Text(error).foregroundStyle(.red) }
                if let error = model.loginItemError { Text(error).foregroundStyle(.red) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            SetupButtonRow {
                Button("Continue") { model.continueFromPermissions() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
        }
        // Cancelled when the step changes or the window closes.
        .task { await model.pollPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.checkPermissions() }
        }
    }
}

private struct PermissionRow<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            accessory
        }
        .padding(.vertical, 7)
    }
}

private struct Done: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityLabel("Done")
    }
}
