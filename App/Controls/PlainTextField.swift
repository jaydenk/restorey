import AppKit
import SwiftUI

/// Text reaches a field by key presses and input methods (`controlTextDidChange`), and by Accessibility value
/// writes from VoiceOver, Voice Control or Switch Control. SwiftUI's own `TextField` misses the last: the
/// display changes but its model doesn't (carry list: assistive input). These fields report every write to
/// the binding, from two places so that whichever route AppKit's Accessibility takes is covered: the
/// documented `setAccessibilityValue(_:)`, and the cell's `stringValue` and `objectValue` setters, which
/// the writes to the field's text end in (`objectValue` is guarded to strings: AppKit also passes it other
/// values). The VoiceOver check is on the hand check list (docs/v0.1-measurements.md).
///
/// Only writes from outside are reported (`CellWrites`): AppKit also writes a cell when its text is *read* during
/// editing (`-[NSCell stringValue]` first commits the editor's text), and the field writes it itself when the binding
/// changes. Reporting those echoed the binding's own value, or an old one, back into it during SwiftUI's update,
/// which looped forever when the binding changed under a field being edited.
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

    /// This field's undo history, owned by the field. Its actions target this field's own editor and text
    /// storage, so they can't outlive what they point at: the history goes when the field does. Without it the
    /// editor used the window's undo manager (AppKit gives an editing session its own only when the editor
    /// doesn't already allow undo), which keeps actions for released fields without retaining their targets:
    /// ⌘Z then crashed on a freed text storage.
    private let fieldUndoManager = UndoManager()

    override class var cellClass: AnyClass? {
        get { ForwardingTextFieldCell.self }
        set {}
    }

    override func setAccessibilityValue(_ value: Any?) { applyAssistiveValue(value) }

    /// The field editor asks its delegate, which is this field while it is being edited, for its undo manager
    /// (`NSTextViewDelegate`). A field whose cell doesn't allow undo (a revealed secret) records nothing.
    @objc(undoManagerForTextView:)
    func undoManager(for view: NSTextView) -> UndoManager? { fieldUndoManager }

    override func menu(for event: NSEvent) -> NSMenu? {
        TextFieldSupport.focusForContextMenu(self)
        return LiteralFieldEditor.minimalMenu()
    }

    /// The history covers one editing session, as AppKit's own does for a text field: the next session may start
    /// from text set by the model, which the old actions' ranges don't describe.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        fieldUndoManager.removeAllActions()
    }

    /// Text put into the field from the binding replaces what the history describes.
    func forgetUndoHistory() { fieldUndoManager.removeAllActions() }
}

/// Plain fields get their own field editor, set up once as literal, instead of the window's shared one. The
/// shared editor keeps whatever it was last given (spelling, data detectors, Writing Tools, inline
/// predictions), none of which belongs on a revealed secret: Writing Tools can send text off the Mac. It also
/// stops those settings leaking onto the window's other fields. A secure field needs no such editor: it
/// is already served by AppKit's secure one, with no text services. Undo is left to the field: AppKit sets
/// `allowsUndo` from the cell each time editing begins, and the undo manager comes from the field.
///
/// The editor is TextKit 1, so its text network (and the text in it) is released with the editor. A TextKit 2
/// editor's text storage outlives it: AppKit's layout fragment views keep it, with the text it last held, which
/// for a revealed secret is the secret.
@MainActor
final class LiteralFieldEditor: NSTextView {
    static func make() -> LiteralFieldEditor {
        let editor = LiteralFieldEditor(usingTextLayoutManager: false)
        editor.isFieldEditor = true
        editor.isRichText = false
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
        let editor = MainActor.assumeIsolated { LiteralFieldEditor.make() }
        literalEditor = editor
        return editor
    }

    /// Empties this cell's own editor, which keeps the last text it edited once editing has ended.
    @MainActor func emptyEditor() { literalEditor?.string = "" }

    let writes = CellWrites()

    override var stringValue: String {
        get { writes.reading { super.stringValue } }
        set {
            super.stringValue = newValue
            writes.report(newValue, from: controlView)
        }
    }

    override var objectValue: Any? {
        get { writes.reading { super.objectValue } }
        set {
            super.objectValue = newValue
            writes.report(newValue, from: controlView)
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

    /// AppKit's secure editor decides what a secret's menu offers (no Cut or Copy); it is shown for this field.
    override func menu(for event: NSEvent) -> NSMenu? {
        TextFieldSupport.focusForContextMenu(self)
        return currentEditor()?.menu(for: event)
    }
}

final class ForwardingSecureTextFieldCell: NSSecureTextFieldCell {
    let writes = CellWrites()

    override var stringValue: String {
        get { writes.reading { super.stringValue } }
        set {
            super.stringValue = newValue
            writes.report(newValue, from: controlView)
        }
    }

    override var objectValue: Any? {
        get { writes.reading { super.objectValue } }
        set {
            super.objectValue = newValue
            writes.report(newValue, from: controlView)
        }
    }
}

/// Which of a forwarding cell's text writes reach the binding: none made while the cell is being read (AppKit's
/// commit of the editor's text) or while the field is showing the binding's own value (`quietly`).
@MainActor
final class CellWrites {
    private var quiet = 0

    func reading<T>(_ read: () -> T) -> T {
        quiet += 1
        defer { quiet -= 1 }
        return read()
    }

    func quietly(_ write: () -> Void) {
        quiet += 1
        defer { quiet -= 1 }
        write()
    }

    func report(_ value: Any?, from controlView: NSView?) {
        guard quiet == 0, let text = value as? String else { return }
        (controlView as? any AssistiveInputField)?.onTextWritten?(text)
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
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// A context menu's commands go to the first responder, so a field that is clicked while another has the
    /// focus takes it first: its menu then acts on this field, not on the other.
    static func focusForContextMenu(_ field: NSTextField) {
        guard field.currentEditor() == nil, field.isEditable, let window = field.window else { return }
        window.makeFirstResponder(field)
    }

    /// Puts a new value of the binding into the field, without echoing it back. During editing the editor's text is
    /// replaced (a composition in progress is dropped: it belonged to the old value) with the caret at the end, and a
    /// plain field's undo history is cleared.
    static func show(_ text: String, in field: NSTextField) {
        let editor = field.currentEditor() as? NSTextView
        guard (editor?.string ?? field.stringValue) != text else { return }
        if let editor, editor.hasMarkedText() {
            editor.unmarkText()
            editor.inputContext?.discardMarkedText()
        }
        writes(of: field)?.quietly { field.stringValue = text }
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
        (field as? ForwardingTextField)?.forgetUndoHistory()
    }

    private static func writes(of field: NSTextField) -> CellWrites? {
        (field.cell as? ForwardingTextFieldCell)?.writes ?? (field.cell as? ForwardingSecureTextFieldCell)?.writes
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
    /// A number's field: right-aligned, in digits of one width, so the numbers line up (`NumberField`, Task 17c).
    var isNumeric = false
    /// What VoiceOver calls the field when its placeholder isn't a name ("0", "None"); nil uses the title.
    var accessibilityName: String?

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
        field.setAccessibilityLabel(accessibilityName ?? title)
        if isNumeric {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        context.coordinator.show(text, in: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: ForwardingTextField, context: Context) -> CGSize? {
        TextFieldSupport.fittingSize(of: field, proposal: proposal)
    }

    static func dismantleNSView(_ field: ForwardingTextField, coordinator: Coordinator) {
        field.onTextWritten = nil
    }

    @MainActor
    final class Coordinator: TextBindingCoordinator {
        var onSubmit: (@MainActor () -> Void)?
        init(text: Binding<String>, onSubmit: (@MainActor () -> Void)?) {
            self.onSubmit = onSubmit
            super.init(text: text)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
            onSubmit()
            return true
        }
    }
}

/// Keeps a field and its binding in step in both directions. `known` is the text both last agreed on: the field
/// sets it when it writes the binding, the binding when it is shown. A binding value that differs from it is a
/// change from outside (another plan loaded, say) and replaces the field's text, even mid-edit; one that equals it
/// is the field's own value coming back and leaves the field alone.
@MainActor
class TextBindingCoordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    private(set) var known: String
    /// True while the field is being given the binding's value: what it reports then (an input method's
    /// composition committed on the way) is the old text, not the user's.
    private var applyingBinding = false

    init(text: Binding<String>) {
        self.text = text
        known = text.wrappedValue
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        take(field.stringValue)
    }

    /// The field's text changed: the binding takes it, unless it already has it.
    func take(_ newText: String) {
        guard !applyingBinding else { return }
        known = newText
        if text.wrappedValue != newText { text.wrappedValue = newText }
    }

    /// Called from `updateNSView` with the binding's value.
    func show(_ value: String, in field: NSTextField) {
        guard value != known else { return }
        known = value
        applyingBinding = true
        defer { applyingBinding = false }
        TextFieldSupport.show(value, in: field)
    }

    /// The field now shows `value` (a new field was set up with it).
    func agree(on value: String) { known = value }
}
