import AppKit
import SwiftUI

/// A secret's field: dots by default, with a "Show" switch that swaps the secure field for a plain one.
/// `NSSecureTextField` turns on secure event input, which stops dead keys and input methods composing
/// (carry list: "ö" by a dead key), so the plain field is where those are typed. The text lives only in the
/// binding and the field showing it; it isn't logged, copied to the pasteboard or kept anywhere else, and the
/// field that is swapped out is emptied. Neither field has an undo history: one would hold the secret.
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

    static func dismantleNSView(_ container: Container, coordinator: Coordinator) {
        guard let field = container.field else { return }
        detach(field)
        empty(field)
    }

    /// Stops a field reaching the binding: emptying or committing its text must not write it.
    private static func detach(_ field: NSTextField) {
        field.delegate = nil
        (field as? any AssistiveInputField)?.onTextWritten = nil
    }

    /// Leaves nothing of the secret in a detached field or its editor. A field's editor keeps the last text it
    /// edited after editing ends, and a retired field can be kept alive by AppKit for a while (AutoFill holds the
    /// last control it served).
    private static func empty(_ field: NSTextField) {
        (field.currentEditor() as? NSTextView)?.string = ""
        field.abortEditing()
        field.stringValue = ""
        (field.cell as? ForwardingTextFieldCell)?.emptyEditor()
    }

    /// Replaces `previous` (if any) with the field for the current `showing`, carrying the focus and caret.
    private func install(in container: Container, coordinator: Coordinator, previous: NSTextField?) {
        coordinator.showing = showing  // first: a binding change below must not start a second swap
        var shown = text
        var committed = false
        if let previous {
            // Detached before anything below changes its text: the binding can't change while SwiftUI is updating
            // this view, and emptying the retired field mustn't empty the binding.
            Self.detach(previous)
            // Focus leaving mid-composition commits what is pending, as it does anywhere else in macOS: a dead key
            // typed but not completed (⌥U, no vowel yet) keeps its "¨" instead of vanishing with the old field.
            if let marked = previous.currentEditor() as? NSTextView, marked.hasMarkedText() {
                marked.unmarkText()
                marked.inputContext?.discardMarkedText()
                previous.validateEditing()
                committed = previous.stringValue != text
                shown = previous.stringValue
            }
        }
        let editor = previous?.currentEditor()
        let selection = editor?.selectedRange
        let wasEditing = editor != nil

        let field: NSTextField = showing ? ForwardingTextField() : ForwardingSecureTextField()
        TextFieldSupport.configure(field, title: title)
        // No undo history for a secret, shown or not: the cell that doesn't allow undo gives its editor no undo
        // manager, so typing registers nothing anywhere.
        field.cell?.allowsUndo = false
        field.delegate = coordinator
        field.stringValue = shown
        (field as? any AssistiveInputField)?.onTextWritten = { [coordinator] in coordinator.take($0) }
        if committed { coordinator.takeAfterUpdate(shown, replacing: text, shownIn: field) }

        if let previous {
            Self.empty(previous)
            previous.removeFromSuperview()
        }
        container.install(field)

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

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            take(field.stringValue)
        }

        func take(_ newText: String) {
            if text.wrappedValue != newText { text.wrappedValue = newText }
        }

        /// The text a swap committed (a pending dead key), written once SwiftUI has finished updating the view: the
        /// binding can't change during the update. Skipped if anything changed meanwhile: the binding (typing in
        /// the new field already wrote newer text) or what the new field shows.
        func takeAfterUpdate(_ committed: String, replacing old: String, shownIn field: NSTextField) {
            Task { @MainActor [weak self, weak field] in
                guard let self, let field, field.stringValue == committed, self.text.wrappedValue == old else { return }
                self.take(committed)
            }
        }
    }
}
