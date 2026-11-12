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
    static func make() -> LiteralFieldEditor {
        let editor = LiteralFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.allowsUndo = true
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
}

final class ForwardingTextFieldCell: NSTextFieldCell {
    private var literalEditor: LiteralFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if let literalEditor { return literalEditor }
        let editor = MainActor.assumeIsolated { LiteralFieldEditor.make() }
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
