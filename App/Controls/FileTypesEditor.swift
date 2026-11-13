import RestoreyCore
import SwiftUI

/// The file types a plan leaves out, as removable tokens with a field to add more. What is typed goes
/// through `Plan.normalisedFileType` (trimmed, lower case, a bare extension), so what is shown is what is
/// saved; anything that isn't an extension is refused with a sentence rather than added.
struct FileTypesEditor: View {
    @Binding var types: [String]
    @State private var entry = ""
    @State private var problem: String?
    /// What `add` left in the field; the sentence stays until the text is changed from that.
    @State private var refused = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if types.isEmpty {
                Text("No file types are left out")
                    .foregroundStyle(.secondary)
            } else {
                TokenFlow(spacing: 6) {
                    ForEach(types, id: \.self) { type in
                        HStack(spacing: 4) {
                            Text(type)
                            Button {
                                types.removeAll { $0 == type }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(type)")
                        }
                        .padding(.vertical, 2)
                        .padding(.leading, 8)
                        .padding(.trailing, 4)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            HStack {
                PlainTextField(title: "File type, such as dmg", text: $entry, onSubmit: add)
                    .frame(maxWidth: 240)
                    .onChange(of: entry) { if entry != refused { problem = nil } }
                Button("Add", action: add)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func add() {
        let result = FormValidation.addingFileTypes(entry, to: types)
        types = result.types
        // Keep what was refused in the field so it can be corrected.
        entry = result.rejected.joined(separator: " ")
        refused = entry
        problem = result.rejected.isEmpty ? nil : FormValidation.sentence(FormValidation.fileTypeProblem(rejected: result.rejected))
    }
}

/// Lays its children out left to right, wrapping onto a new line when the row is full.
struct TokenFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
