import AppKit
import RestoreyCore
import SwiftUI

/// The folders and drives a plan backs up: a bordered list with "Add Folder or Drive…" and "Remove".
/// Paths are stored as absolute paths (the agent refuses anything else); the list shows them with `~` for
/// the home folder.
///
/// Folders dragged in from Finder are added by the same rule as the button's (`FolderDrop`: only folders and drives,
/// nothing listed twice, nothing already inside a listed folder, nothing in the plan's own repository), with the list
/// ringed while the drag is over it; what the rule leaves out is said under the list, and what it did that isn't a
/// problem (folders a new one replaced, the repository left out of one) as a note below that. Delete (⌫ or ⌦) removes the selected rows as Remove does, and a row's context menu has Show in Finder and
/// Remove (Task 17e, audit T3 and T4). Settings' Folders tab and setup's sources step share it.
struct SourcesEditor: View {
    @Binding var sources: [String]
    /// The plan's repository, so a folder it is in can't be added and one holding it says it is left out; nil before
    /// setup has chosen one.
    let repository: Repository?
    @State private var selection: Set<String> = []
    /// Why the last add (button or drop) left something out; cleared by the next change to the list.
    @State private var addProblem: String?
    /// What the last add did that isn't a problem (folders it replaced, the repository left out); cleared with `addProblem`.
    @State private var addNote: String?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(sources, id: \.self) { path in
                    Text(FormValidation.displayPath(path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                        .tag(path)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 80, idealHeight: 110)
            .overlay {
                if sources.isEmpty {
                    Text("No folders or drives yet")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Folders and drives to back up")
            .contextMenu(forSelectionType: String.self) { paths in
                if !paths.isEmpty {
                    Button("Show in Finder") { reveal(paths) }
                    // Dimmed exactly when the Remove button and the Delete key can't act: the list is disabled.
                    Button("Remove") { remove(paths) }
                        .disabled(!isEnabled)
                }
            }
            .onDeleteCommand(perform: selection.isEmpty || !isEnabled ? nil : { remove(selection) })
            .acceptsDroppedFolders(isEnabled: isEnabled) { add($0) }
            .onChange(of: sources) { selection.formIntersection(sources) }
            if let addProblem {
                SeverityText(addProblem, severity: .warning)
            }
            if let addNote {
                Text(addNote).explanatoryNote()
            }
            HStack {
                Button("Add Folder or Drive…", action: choose)
                Button("Remove") { remove(selection) }
                    .disabled(selection.isEmpty)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose the folders and drives to back up."
        Task { @MainActor in
            guard await panel.presentForKeyWindow() == .OK else { return }
            add(panel.urls)
        }
    }

    /// The button's and a drop's one way in. What the items are, and where they and the folders they are compared
    /// with lead, is read off the main actor (`FolderDrop.look`, within its 10 s deadline, L157); the rule is then
    /// applied to the list as it is by then.
    private func add(_ urls: [URL]) {
        let home = NSHomeDirectory()
        let compared = sources + [repository?.localFolderPath, home].compactMap { $0 }
        Task { @MainActor in
            let look = await FolderDrop.look(at: urls, against: compared)
            let outcome = FolderDrop.addingSources(
                look.items, to: sources, repository: repository, home: home, leads: look.leads)
            sources = outcome.list
            addProblem = outcome.problem
            addNote = outcome.note
        }
    }

    private func remove(_ paths: Set<String>) {
        sources.removeAll { paths.contains($0) }
        selection.subtract(paths)
        addProblem = nil
        addNote = nil
    }

    private func reveal(_ paths: Set<String>) {
        NSWorkspace.shared.activateFileViewerSelecting(
            sources.filter(paths.contains).map { URL(fileURLWithPath: $0) })
    }
}
