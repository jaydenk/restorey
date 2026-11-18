import RestoreyCore
import SwiftUI

/// A list that takes folders dragged from Finder (Task 17e, audit T3): the list is ringed in the accent colour while a
/// drag is over it, as Finder's own drop targets are, and `onDrop` gets the dropped items, to add through the same
/// rule as the list's add button (`FolderDrop`), each item read by `PickedItem.classify` (RestoreyCore).
///
/// `dropDestination(for:isEnabled:action:)` (macOS 26) takes the files as `URL`s; `onDropSessionUpdated` (macOS 26) reports
/// the drag entering and leaving, which draws the ring.
struct FolderDropTarget: ViewModifier {
    let isEnabled: Bool
    let onDrop: ([PickedItem]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self, isEnabled: isEnabled) { urls, _ in
                targeted = false
                onDrop(PickedItem.classify(urls))
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

extension View {
    func acceptsDroppedFolders(isEnabled: Bool = true, _ onDrop: @escaping ([PickedItem]) -> Void) -> some View {
        modifier(FolderDropTarget(isEnabled: isEnabled, onDrop: onDrop))
    }
}
