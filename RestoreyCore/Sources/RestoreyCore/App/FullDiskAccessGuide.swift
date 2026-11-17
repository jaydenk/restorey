import Foundation

/// What setup's Permissions step and Settings → General say about Full Disk Access, and which item the person drags
/// into System Settings (Task 16c). Pure; the views read the agent's last probe (`AgentStatus.fdaMissing`) and show
/// this. The app never probes on its own.
public enum FullDiskAccessGuide {
    public enum State: Sendable, Equatable {
        /// The agent has not answered yet.
        case checking
        case missing
        case granted

        /// `fdaMissing` as the agent reports it: nil until its probe has run.
        public init(missing: Bool?) {
            switch missing {
            case nil: self = .checking
            case true?: self = .missing
            case false?: self = .granted
            }
        }
    }

    /// Shown with a green tick, and no button, once the agent finds access granted.
    public static let grantedTitle = "Full Disk Access is on"

    /// What is missed without it: the folders the agent's probe lists (`FullDiskAccessProbe.protectedDirectories`:
    /// Safari, Mail, Messages) are the ones named. "Other protected folders" is Apple's wider set (Photos, Notes,
    /// Time Machine backups and so on), which Full Disk Access also covers.
    public static let why = "Without it, Restorey can't back up Mail, Messages, Safari and other protected folders."

    /// Under the tile.
    public static let dragCaption = "Drag this into the list, then switch it on."

    /// The item System Settings' Full Disk Access list must hold: the app bundle. The agent is registered with
    /// `SMAppService` from inside it, so macOS makes the app the responsible code for the agent and the restic it
    /// launches (spike H1: the TCC subject was the app's bundle ID and the list gained no other entry). Given any
    /// path inside the bundle (the agent binary under `Contents/Helpers`, say) this is still the outermost `.app`.
    /// Nil if the URL is not inside an app bundle.
    public static func dragItemURL(forBundleAt url: URL) -> URL? {
        var path = url.standardizedFileURL.pathComponents
        guard let index = path.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        path = Array(path[...index])
        return URL(fileURLWithPath: NSString.path(withComponents: path), isDirectory: true)
    }
}
