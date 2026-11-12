import RestoreyCore
import ServiceManagement

/// Open at login: the app itself registered with `SMAppService.mainApp` (P2-16; on by default, set in setup's
/// permissions step, and switched in Settings → General). Made only for the installed copy, like
/// `AgentRegistration`: a copy in `~/Downloads` must not register itself to open at every login.
@MainActor
struct LoginItem {
    init(installed: InstalledCopy) {}

    private var service: SMAppService { .mainApp }

    var status: AgentServiceStatus { AgentServiceStatus(service.status) }

    var isEnabled: Bool { loginItemIsEnabled(status) }

    /// Registers or unregisters the app. Never registers an enabled app or unregisters one that isn't
    /// registered (`loginItemChange`), so the only errors are real ones.
    func setEnabled(_ enabled: Bool) throws {
        switch loginItemChange(from: status, enable: enabled) {
        case .none: break
        case .register: try service.register()
        case .unregister: try service.unregister()
        }
    }

    /// Where the user switches a login item back on once they've switched it off (`requiresApproval`).
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
