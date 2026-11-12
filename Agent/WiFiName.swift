import CoreWLAN

/// The name of the Wi-Fi network the Mac is on, for the "skip on these Wi-Fi networks" rule (Ruling P2-8).
enum WiFiName {
    /// The default Wi-Fi interface's SSID, or nil when the Mac isn't on Wi-Fi, has no Wi-Fi interface, or
    /// the name can't be read. macOS reveals the name only to a process with Location Services
    /// authorisation (`LocationPermission`); without it this is nil, which never skips a backup.
    static func current() -> String? {
        guard let name = CWWiFiClient.shared().interface()?.ssid(), !name.isEmpty else { return nil }
        return name
    }
}
