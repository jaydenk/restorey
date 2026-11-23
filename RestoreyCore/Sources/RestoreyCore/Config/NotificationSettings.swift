import Foundation

/// Which notifications Restorey posts, Mac-wide, kept in `config.json` beside the network rules
/// (`ConfigFile.notifications`). Additive to schema 5: a config without the key decodes to `defaults`.
/// JSON: `{"backupStarted":false,"backupFinished":false,"problems":true}`.
public struct NotificationSettings: Codable, Sendable, Equatable {
    /// Post when a backup's restic step starts.
    public var backupStarted: Bool
    /// Post when a backup ends having saved its data (success, unchanged or a warning).
    public var backupFinished: Bool
    /// Post the alerts for problems with backups. Off stops the posting only: the alerts are still raised, so the
    /// menu bar icon, the menu's banners and check-in pings behave as before.
    public var problems: Bool

    public init(backupStarted: Bool, backupFinished: Bool, problems: Bool) {
        self.backupStarted = backupStarted
        self.backupFinished = backupFinished
        self.problems = problems
    }

    /// Started off, finished off, problems on.
    public static let defaults = NotificationSettings(backupStarted: false, backupFinished: false, problems: true)

    private enum CodingKeys: String, CodingKey { case backupStarted, backupFinished, problems }

    /// Hand-written so a missing key takes its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backupStarted = try c.decodeIfPresent(Bool.self, forKey: .backupStarted) ?? Self.defaults.backupStarted
        backupFinished = try c.decodeIfPresent(Bool.self, forKey: .backupFinished) ?? Self.defaults.backupFinished
        problems = try c.decodeIfPresent(Bool.self, forKey: .problems) ?? Self.defaults.problems
    }
}
