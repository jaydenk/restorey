import AppKit
import RestoreyCore
import SwiftUI

/// Full Disk Access in setup's Permissions step and Settings → General (Task 16c): while it is missing, the one-line why,
/// a tile with the icon and name of the app to add (draggable into System Settings' Full Disk Access list) and the
/// button that opens that pane; once the agent finds it on, a green tick and "Full Disk Access is on" and nothing to
/// press. It only shows the agent's last answer (`state`); it never probes or asks for anything itself.
struct FullDiskAccessBlock: View {
    let state: FullDiskAccessGuide.State
    let openSettings: () -> Void
    /// The running app is the installed copy here: both screens exist only for one (`InstalledCopy`).
    private let appURL = FullDiskAccessGuide.dragItemURL(forBundleAt: Bundle.main.bundleURL)

    var body: some View {
        switch state {
        case .granted:
            Label {
                Text(FullDiskAccessGuide.grantedTitle)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .missing:
            VStack(alignment: .leading, spacing: 10) {
                Text(FullDiskAccessGuide.why)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center, spacing: 12) {
                    if let appURL { DragTile(url: appURL) }
                    Text(FullDiskAccessGuide.dragCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Settings…", action: openSettings)
            }
        }
    }
}

/// The app's icon and name, dragged as a file URL (`public.file-url`, which is what Finder drags and what the list
/// accepts). `NSItemProvider(object: NSURL)` registers `public.file-url` and `public.url`, checked by hand.
private struct DragTile: View {
    let url: URL

    var body: some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        VStack(spacing: 4) {
            Image(nsImage: icon).resizable().frame(width: 48, height: 48)
            Text(FileManager.default.displayName(atPath: url.path)).font(.caption)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onDrag {
            NSItemProvider(object: url as NSURL)
        } preview: {
            Image(nsImage: icon).resizable().frame(width: 48, height: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag into the Full Disk Access list in System Settings")
    }
}
