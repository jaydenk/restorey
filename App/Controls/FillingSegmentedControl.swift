import AppKit
import SwiftUI

/// A segmented control that spans the width it is given, with every segment the same width
/// (`NSSegmentedControl.segmentDistribution = .fillEqually`). SwiftUI's segmented `Picker` on the Mac sizes each
/// segment to its label and stops short of the fields beneath it, so a choice above a form (setup's "Where backups
/// go") looked ragged (owner's live check, 24 Nov 2026). Enabled and disabled follow SwiftUI's `disabled(_:)`;
/// VoiceOver names it `name`, and the arrow keys move between segments as in any segmented control.
struct FillingSegmentedControl<Value: Hashable>: NSViewRepresentable {
    let name: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.title), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(name)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = context.environment.isEnabled
        if let index = options.firstIndex(where: { $0.value == selection }), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: max(proposal.width ?? natural.width, natural.width), height: natural.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: FillingSegmentedControl
        init(_ parent: FillingSegmentedControl) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].value
        }
    }
}
