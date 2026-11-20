import RestoreyCore
import SwiftUI

/// A list that takes folders dragged from Finder (Task 17e, audit T3): the list is ringed in the accent colour while a
/// drag is over it, as Finder's own drop targets are, and `onDrop` gets the dropped URLs, to add through the same
/// rule as the list's add button (`FolderDrop`), each item read by `FolderDrop.look` (RestoreyCore) off the main actor.
///
/// `dropDestination(for:isEnabled:action:)` (macOS 26) takes the files as `URL`s; `onDropSessionUpdated` (macOS 26) reports
/// the drag entering and leaving, which draws the ring.
struct FolderDropTarget: ViewModifier {
    let isEnabled: Bool
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self, isEnabled: isEnabled) { urls, _ in
                targeted = false
                onDrop(urls)
            }
            .onDropSessionUpdated { session in
                // Ringed only while the drag is over the list: entering or moving within it.
                switch session.phase {
                case .entering, .active: targeted = true
                default: targeted = false
                }
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Records an add judged by the paths as written (`FolderDrop.Look.checkedInTime` false), naming them, as the agent
/// logs its own link checks that don't answer.
func logUnchecked(_ look: FolderDrop.Look, log: AppLog?, list: String) {
    let paths = look.items.map(\.path).joined(separator: ", ")
    log?.info("\(list) list: the disk wasn’t checked in time (or an earlier check is stuck), so these were judged by "
        + "their paths, links not followed: \(paths)")
}

extension View {
    func acceptsDroppedFolders(isEnabled: Bool = true, _ onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FolderDropTarget(isEnabled: isEnabled, onDrop: onDrop))
    }
}
