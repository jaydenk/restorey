import AppKit
import SwiftUI

/// Text reaches a field by key presses and input methods (`controlTextDidChange`), and by Accessibility value
/// writes from VoiceOver, Voice Control or Switch Control. SwiftUI's own `TextField` misses the last: the
/// display changes but its model doesn't (carry list: assistive input). These fields report every write to
/// the binding, from two places so that whichever route AppKit's Accessibility takes is covered: the
/// documented `setAccessibilityValue(_:)`, and the cell's `stringValue` and `objectValue` setters, which
/// the writes to the field's text end in (`objectValue` is guarded to strings: AppKit also passes it other
/// values). The VoiceOver check is on the hand check list (docs/v0.1-measurements.md).
@MainActor
protocol AssistiveInputField: NSTextField {
    /// Called with the field's text after it was written to other than by the user typing.
    var onTextWritten: (@MainActor (String) -> Void)? { get set }
}

extension AssistiveInputField {
    /// A value written through Accessibility becomes the field's text, exactly as if it had been typed.
    fileprivate func applyAssistiveValue(_ value: Any?) {
        guard let text = value as? String else { return }
        stringValue = text
        onTextWritten?(text)
    }
}

/// An `NSTextField` that reports writes to its text.
final class ForwardingTextField: NSTextField, AssistiveInputField {
    var onTextWritten: (@MainActor (String) -> Void)?
    /// False for a field showing a secret: its editor then registers no undo actions.
    var keepsUndoHistory = true

    override class var cellClass: AnyClass? {
        get { ForwardingTextFieldCell.self }
        set {}
    }

    override func setAccessibilityValue(_ value: Any?) { applyAssistiveValue(value) }
}

/// Plain fields get their own field editor, set up once as literal, instead of the window's shared one. The
/// shared editor keeps whatever it was last given (spelling, data detectors, Writing Tools, inline
/// predictions), none of which belongs on a revealed secret: Writing Tools can send text off the Mac. It also
/// stops those settings leaking onto the window's other fields. A secure field needs no such editor: it
/// is already served by AppKit's secure one, with no text services.
@MainActor
final class LiteralFieldEditor: NSTextView {
    /// NSTextField switches `allowsUndo` on whenever it takes a field editor, so a secret's editor answers
    /// `false` here whatever it is told. Typing may still register an action, so `UndoPurge` is what guarantees
    /// that none is left behind when the field is left or retired.
    private var undoPermitted = true
    override var allowsUndo: Bool {
        get { undoPermitted && super.allowsUndo }
        set { super.allowsUndo = newValue }
    }

    static func make(allowsUndo: Bool) -> LiteralFieldEditor {
        let editor = LiteralFieldEditor(frame: .zero)
        editor.undoPermitted = allowsUndo
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.allowsUndo = allowsUndo
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.enabledTextCheckingTypes = 0
        editor.writingToolsBehavior = .none
        editor.inlinePredictionType = .no
        return editor
    }

    /// Cut, Copy, Paste and Select All, nothing else: no Spelling and Grammar, Substitutions, Transformations,
    /// Speech, Writing Tools or Services. (AppKit asks the field editor, which is the view that is clicked.)
    override func menu(for event: NSEvent) -> NSMenu? { LiteralFieldEditor.minimalMenu() }

    static func minimalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        return menu
    }
}

final class ForwardingTextFieldCell: NSTextFieldCell {
    private var literalEditor: LiteralFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if let literalEditor { return literalEditor }
        // A revealed secret keeps no undo history (`UndoPurge`): it would hold the secret, and outlive the editor.
        let allowsUndo = (controlView as? ForwardingTextField)?.keepsUndoHistory ?? true
        let editor = MainActor.assumeIsolated { LiteralFieldEditor.make(allowsUndo: allowsUndo) }
        literalEditor = editor
        return editor
    }

    override var stringValue: String {
        get { super.stringValue }
        set {
            super.stringValue = newValue
            (controlView as? ForwardingTextField)?.onTextWritten?(newValue)
        }
    }

    override var objectValue: Any? {
        get { super.objectValue }
        set {
            super.objectValue = newValue
            if let text = newValue as? String { (controlView as? ForwardingTextField)?.onTextWritten?(text) }
        }
    }
}

/// An `NSSecureTextField` that reports writes to its text.
final class ForwardingSecureTextField: NSSecureTextField, AssistiveInputField {
    var onTextWritten: (@MainActor (String) -> Void)?

    override class var cellClass: AnyClass? {
        get { ForwardingSecureTextFieldCell.self }
        set {}
    }

    override func setAccessibilityValue(_ value: Any?) { applyAssistiveValue(value) }
}

final class ForwardingSecureTextFieldCell: NSSecureTextFieldCell {
    override var stringValue: String {
        get { super.stringValue }
        set {
            super.stringValue = newValue
            (controlView as? ForwardingSecureTextField)?.onTextWritten?(newValue)
        }
    }

    override var objectValue: Any? {
        get { super.objectValue }
        set {
            super.objectValue = newValue
            if let text = newValue as? String { (controlView as? ForwardingSecureTextField)?.onTextWritten?(text) }
        }
    }
}

/// Undo actions point at the editor (and its text storage) and the cell that typed them, none of which the undo
/// manager keeps alive. When SwiftUI releases a field, an action left behind is a dangling target the next
/// Undo invokes (EXC_BAD_ACCESS in `-[NSUndoManager undoNestedGroup]`). Retiring a field removes every action
/// aimed at its parts, from every manager that could hold one, and empties a cell undo manager outright (it is
/// the field editor's own, never shared with other fields' text).
@MainActor
enum UndoPurge {
    static func retire(_ field: NSTextField) {
        let editor = field.currentEditor() as? NSTextView
        var targets: [AnyObject] = [field]
        if let cell = field.cell { targets.append(cell) }
        if let editor {
            targets.append(editor)
            if let storage = editor.textStorage { targets.append(storage) }
            if let layout = editor.layoutManager { targets.append(layout) }
            if let container = editor.textContainer { targets.append(container) }
        }
        var managers: [UndoManager] = []
        for manager in [field.undoManager, editor?.undoManager, field.window?.undoManager] {
            if let manager, !managers.contains(where: { $0 === manager }) { managers.append(manager) }
        }
        for manager in managers {
            for target in targets { manager.removeAllActions(withTarget: target) }
            if NSStringFromClass(type(of: manager)) == "NSCellUndoManager" { manager.removeAllActions() }
        }
    }
}

/// Shared set-up and updating for the text field representables.
@MainActor
enum TextFieldSupport {
    static func configure(_ field: NSTextField, title: String) {
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.isEditable = true
        // No Writing Tools, completion or character picker on any of these fields (a secret may be revealed).
        field.allowsWritingTools = false
        field.allowsWritingToolsAffordance = false
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.menu = LiteralFieldEditor.minimalMenu()
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Puts the binding's text into the field, unless it already shows it or an input method is part-way
    /// through composing (replacing the string then would cancel the composition).
    static func show(_ text: String, in field: NSTextField) {
        guard field.stringValue != text else { return }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        field.stringValue = text
    }

    static func fittingSize(of field: NSTextField, proposal: ProposedViewSize) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: field.intrinsicContentSize.height)
    }
}

/// A single-line text field whose text reaches the binding from key presses, input methods and Accessibility
/// value writes alike (carry list: assistive input). The title is the placeholder and the accessibility label.
struct PlainTextField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    /// Called when Return is pressed in the field.
    var onSubmit: (@MainActor () -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> ForwardingTextField {
        let field = ForwardingTextField()
        TextFieldSupport.configure(field, title: title)
        field.delegate = context.coordinator
        field.stringValue = text
        field.onTextWritten = { [coordinator = context.coordinator] in coordinator.take($0) }
        return field
    }

    func updateNSView(_ field: ForwardingTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        TextFieldSupport.show(text, in: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: ForwardingTextField, context: Context) -> CGSize? {
        TextFieldSupport.fittingSize(of: field, proposal: proposal)
    }

    static func dismantleNSView(_ field: ForwardingTextField, coordinator: Coordinator) {
        field.onTextWritten = nil
        UndoPurge.retire(field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (@MainActor () -> Void)?
        init(text: Binding<String>, onSubmit: (@MainActor () -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
            onSubmit()
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            take(field.stringValue)
        }

        /// The field's text changed: the binding takes it, unless it already has it.
        func take(_ newText: String) {
            if text.wrappedValue != newText { text.wrappedValue = newText }
        }
    }
}
