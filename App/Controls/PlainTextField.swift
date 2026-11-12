import AppKit
import SwiftUI

/// Text reaches a field by key presses and input methods (`controlTextDidChange`), and by Accessibility value
/// writes from VoiceOver, Voice Control or Switch Control. SwiftUI's own `TextField` misses the last: the
/// display changes but its model doesn't (carry list: assistive input). These fields report every write to
/// the binding, from two places so that whichever route AppKit's Accessibility takes is covered: the
/// documented `setAccessibilityValue(_:)`, and the cell's `objectValue` setter, which every write to the
/// field's text ends in. The VoiceOver check is on the hand check list (docs/v0.1-measurements.md).
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

final class ForwardingTextFieldCell: NSTextFieldCell {
    override var objectValue: Any? {
        get { super.objectValue }
        set {
            super.objectValue = newValue
            (controlView as? ForwardingTextField)?.onTextWritten?(stringValue)
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
    override var objectValue: Any? {
        get { super.objectValue }
        set {
            super.objectValue = newValue
            (controlView as? ForwardingSecureTextField)?.onTextWritten?(stringValue)
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

    /// Names, paths, endpoints and secrets are typed exactly as given: no smart quotes or dashes, no text
    /// replacement, no spelling or completion. The field editor is shared by every field in the window, so
    /// this is applied each time editing begins.
    static func makeLiteral(_ field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
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

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { TextFieldSupport.makeLiteral(field) }
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
