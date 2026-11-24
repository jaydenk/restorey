import RestoreyCore
import SwiftUI

/// The file types a plan leaves out, as a selectable list with the joined + and − buttons. + opens a popover holding
/// the field and Add; − removes the selected types. What is typed goes through `Plan.normalisedFileType` (trimmed,
/// lower case, a bare extension), so what is shown is what is saved; anything that isn't an extension is refused with
/// a sentence, in the popover, rather than added. Delete (⌫ or ⌦) removes the selection as − does.
struct FileTypesEditor: View {
    @Binding var types: [String]
    @State private var selection: Set<String> = []
    @State private var adding = false
    @State private var entry = ""
    @State private var problem: String?
    /// What `add` left in the field; the sentence stays until the text is changed from that.
    @State private var refused = ""
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        BorderedList(
            addName: "Add File Type…", removeName: "Remove File Type", canRemove: isEnabled && !selection.isEmpty,
            isAddPresented: $adding, remove: { remove(selection) }
        ) {
            TypedAddPopover(
                title: "File type, such as dmg", text: $entry,
                canAdd: !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onAdd: add
            ) {
                if let problem {
                    SeverityText(problem)
                }
            }
            .onChange(of: entry) { if entry != refused { problem = nil } }
        } content: {
            List(selection: $selection) {
                ForEach(types, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .frame(height: 90)
            .overlay {
                if types.isEmpty {
                    Text("No file types are left out")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("File types left out")
            .onDeleteCommand(perform: selection.isEmpty || !isEnabled ? nil : { remove(selection) })
            .onChange(of: types) { selection.formIntersection(types) }
        }
        .onChange(of: adding) { if adding { problem = nil; refused = ""; entry = "" } }
    }

    private func remove(_ removed: Set<String>) {
        types.removeAll { removed.contains($0) }
        selection.subtract(removed)
    }

    /// Adds what was typed; the popover closes when all of it was taken, and stays, with the sentence, when not.
    private func add() {
        let result = FormValidation.addingFileTypes(entry, to: types)
        types = result.types
        // Keep what was refused in the field so it can be corrected.
        entry = result.rejected.joined(separator: " ")
        refused = entry
        problem = result.rejected.isEmpty ? nil : FormValidation.sentence(FormValidation.fileTypeProblem(rejected: result.rejected))
        if result.rejected.isEmpty { adding = false }
    }
}
