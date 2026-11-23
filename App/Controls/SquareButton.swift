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

/// A list with the Mac's joined + and − buttons: one rounded border (the system's bordered-list stroke and corner
/// radius) around the list and, at its bottom edge, a bar of two square buttons set off by a hairline, with no gap, as
/// System Settings, Finder's sidebar settings and Mail's accounts have them (HIG Lists and tables). The content is a
/// `List`; it is given the inset style so there aren't two borders, and keeps whatever frame and modifiers the caller
/// puts on it. The buttons' VoiceOver names and help tags are `addName` and `removeName`.
///
/// A list that adds by typing (file types, Wi-Fi names) passes `isAddPresented` and a `popover`: + then shows the
/// popover, anchored to the button, instead of calling an action.
struct BorderedList<Content: View, AddPopover: View>: View {
    let addName: String
    let removeName: String
    let canAdd: Bool
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void
    private let addPopover: AddPopover
    private let isAddPresented: Binding<Bool>?
    private let content: Content

    /// The system's bordered list: its stroke and corner radius.
    static var cornerRadius: CGFloat { 5 }

    var body: some View {
        VStack(spacing: 0) {
            content
                .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            HStack(spacing: 0) {
                addButton
                SquareButton(systemImage: "minus", name: removeName, action: remove).disabled(!canRemove)
                Spacer(minLength: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var addButton: some View {
        if let isAddPresented {
            SquareButton(systemImage: "plus", name: addName) { isAddPresented.wrappedValue = true }
                .disabled(!canAdd)
                .popover(isPresented: isAddPresented, arrowEdge: .bottom) { addPopover }
        } else {
            SquareButton(systemImage: "plus", name: addName, action: add).disabled(!canAdd)
        }
    }
}

extension BorderedList where AddPopover == EmptyView {
    init(
        addName: String, removeName: String, canAdd: Bool = true, canRemove: Bool = true,
        add: @escaping () -> Void, remove: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) {
        self.addName = addName
        self.removeName = removeName
        self.canAdd = canAdd
        self.canRemove = canRemove
        self.add = add
        self.remove = remove
        self.addPopover = EmptyView()
        self.isAddPresented = nil
        self.content = content()
    }
}

extension BorderedList {
    /// A list whose + opens `popover` (bound to `isAddPresented`) in place of an action.
    init(
        addName: String, removeName: String, canAdd: Bool = true, canRemove: Bool = true,
        isAddPresented: Binding<Bool>, remove: @escaping () -> Void,
        @ViewBuilder popover: () -> AddPopover, @ViewBuilder content: () -> Content
    ) {
        self.addName = addName
        self.removeName = removeName
        self.canAdd = canAdd
        self.canRemove = canRemove
        self.add = {}
        self.remove = remove
        self.addPopover = popover()
        self.isAddPresented = isAddPresented
        self.content = content()
    }
}

/// The popover a typed add opens from a list's +: a field that takes focus, an Add button, and the problem or note
/// under them. Return adds (the caller closes the popover when it worked); Esc closes it (the popover's own).
struct TypedAddPopover<Footer: View>: View {
    let title: String
    @Binding var text: String
    let canAdd: Bool
    let onAdd: () -> Void
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PlainTextField(title: title, text: $text, onSubmit: { if canAdd { onAdd() } }, focusesWhenShown: true)
                    .frame(width: 200)
                Button("Add", action: onAdd)
                    .disabled(!canAdd)
            }
            footer
        }
        .padding(12)
        .frame(minWidth: 280, alignment: .leading)
    }
}
