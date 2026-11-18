import AppKit
import SwiftUI

/// A square (gradient) button with a symbol, for the add and remove buttons under a list (HIG Buttons, "Square
/// buttons": they act on the view they sit beneath, contain a symbol rather than text, and need no label). SwiftUI has
/// no such style, so this is AppKit's own `NSButton` with the `.smallSquare` bezel; the help tag and the VoiceOver name
/// are `name`. Enabled and disabled follow SwiftUI's `disabled(_:)`.
struct SquareButton: NSViewRepresentable {
    let systemImage: String
    let name: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: systemImage, accessibilityDescription: name) ?? NSImage(),
            target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.toolTip = name
        button.setAccessibilityLabel(name)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 24, height: 22)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}

/// The add and remove buttons under a bordered list, as Mail's Accounts and Users & Groups have them.
struct ListAddRemoveBar: View {
    let addName: String
    let removeName: String
    let add: () -> Void
    let remove: () -> Void
    var canAdd = true
    var canRemove = true

    var body: some View {
        HStack(spacing: 0) {
            SquareButton(systemImage: "plus", name: addName, action: add).disabled(!canAdd)
            SquareButton(systemImage: "minus", name: removeName, action: remove).disabled(!canRemove)
            Spacer(minLength: 0)
        }
    }
}
