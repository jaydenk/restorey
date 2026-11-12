import AppKit
import SwiftUI

/// A secret's field: dots by default, with a "Show" switch that swaps the secure field for a plain one.
/// `NSSecureTextField` turns on secure event input, which stops dead keys and input methods composing
/// (carry list: "ö" by a dead key), so the plain field is where those are typed. The text lives only in the
/// binding and the field showing it; it isn't logged, copied to the pasteboard or kept anywhere else, and the
/// field that is swapped out is emptied.
struct SecretField: View {
    let title: String
    @Binding var text: String
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            SwappingSecretField(title: title, text: $text, showing: showing)
            Toggle("Show", isOn: $showing)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Show \(title)")
        }
    }
}

/// One container whose single subview is a secure or a plain field. Swapping keeps the text (from the
/// binding) and, when the old field was being edited, makes the new one first responder with the same
/// selection.
struct SwappingSecretField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let showing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        install(in: container, coordinator: context.coordinator, previous: nil)
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.showing != showing {
            install(in: container, coordinator: context.coordinator, previous: container.field)
        } else if let field = container.field {
            field.placeholderString = title
            field.setAccessibilityLabel(title)
            TextFieldSupport.show(text, in: field)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView container: Container, context: Context) -> CGSize? {
        container.field.map { TextFieldSupport.fittingSize(of: $0, proposal: proposal) }
    }

    /// Replaces `previous` (if any) with the field for the current `showing`, carrying the focus and caret.
    private func install(in container: Container, coordinator: Coordinator, previous: NSTextField?) {
        let editor = previous?.currentEditor()
        let selection = editor?.selectedRange
        let wasEditing = editor != nil

        let field: NSTextField = showing ? ForwardingTextField() : ForwardingSecureTextField()
        TextFieldSupport.configure(field, title: title)
        field.delegate = coordinator
        field.stringValue = text
        (field as? any AssistiveInputField)?.onTextWritten = { [coordinator] in coordinator.take($0) }

        if let previous {
            previous.delegate = nil
            (previous as? any AssistiveInputField)?.onTextWritten = nil
            previous.stringValue = ""
            previous.removeFromSuperview()
        }
        container.install(field)
        coordinator.showing = showing

        if wasEditing, let window = container.window {
            window.makeFirstResponder(field)
            if let selection, let newEditor = field.currentEditor() {
                newEditor.selectedRange = NSRange(
                    location: min(selection.location, newEditor.string.utf16.count),
                    length: min(selection.length, max(0, newEditor.string.utf16.count - selection.location)))
            }
        }
    }

    final class Container: NSView {
        private(set) var field: NSTextField?

        func install(_ field: NSTextField) {
            self.field = field
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor),
                field.topAnchor.constraint(equalTo: topAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        /// Which kind of field the container holds now.
        var showing: Bool?
        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { TextFieldSupport.makeLiteral(field) }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            take(field.stringValue)
        }

        func take(_ newText: String) {
            if text.wrappedValue != newText { text.wrappedValue = newText }
        }
    }
}
