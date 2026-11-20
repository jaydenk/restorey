import AppKit
import RestoreyCore
import SwiftUI

/// What a plan leaves out, as a sheet (setup's sources step and Settings' Folders tab): folders (restic patterns;
/// Restorey's own folders stay), file types, and whether other file systems mounted inside a source are skipped.
/// Folders dragged in from Finder are left out by the same rule as "Add Folder…" (`FolderDrop`), with the list ringed
/// while the drag is over it, and Delete (⌫ or ⌦) removes the selected rows as Remove does (Task 17e, audit T3).
struct ExclusionsSheet: View {
    @Binding var exclusions: [String]
    @Binding var fileTypes: [String]
    @Binding var oneFileSystem: Bool
    let home: URL
    let identity: Identity
    /// The plan's repository and sources, for the fixed row naming the repository when it is inside a source.
    let repository: Repository?
    let sources: [String]
    @State private var selection: Set<String> = []
    /// Why the last add (button or drop) left something out; cleared by the next change to the list.
    @State private var addProblem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let own = Set(DefaultExclusions.ownFolders(home: home, identity: identity))
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclusions").pageTitle()
            Text("Folders").font(.headline)
            List(selection: $selection) {
                if let repositoryPath = ExclusionsSummary.repositoryRow(repository: repository, sources: sources) {
                    repositoryRow(repositoryPath)
                }
                ForEach(exclusions, id: \.self) { pattern in
                    HStack {
                        Text(DefaultExclusions.displayPattern(pattern, home: home))
                            .lineLimit(1).truncationMode(.middle)
                        if own.contains(pattern) {
                            Spacer()
                            Text("Restorey’s own").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(pattern)
                    .tag(pattern)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 140, idealHeight: 180)
            .accessibilityLabel("Folders left out")
            .onDeleteCommand(perform: selection.subtracting(own).isEmpty ? nil : { remove(own: own) })
            .acceptsDroppedFolders { add($0) }
            if let addProblem {
                SeverityText(addProblem, severity: .warning)
            }
            HStack {
                Button("Add Folder…", action: addFolder)
                Button("Remove") { remove(own: own) }
                    .disabled(selection.subtracting(own).isEmpty)
            }
            Text("File types").font(.headline)
            FileTypesEditor(types: $fileTypes)
            Toggle("Skip other file systems mounted inside these folders", isOn: $oneFileSystem)
            Text("Such as a network share or a connected iPhone. A drive you add as a source is still backed up.")
                .explanatoryNote()
            Text("iCloud files that aren’t on this Mac are always skipped.")
                .explanatoryNote()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .dismissesOnEscape()
        .frame(width: 520)
    }

    /// The plan's repository, always left out by the agent (so it isn't in `exclusions`): first, with no tag so it can't
    /// be selected, and so Remove and Delete never reach it.
    private func repositoryRow(_ path: String) -> some View {
        HStack {
            Text(FormValidation.displayPath(path, home: home.path))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("This plan’s backups").font(.caption).foregroundStyle(.secondary)
        }
        .help(path)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(FormValidation.displayPath(path, home: home.path)), this plan’s backups, always left out")
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Leave Out"
        panel.message = "Choose the folders to leave out of the backup."
        Task { @MainActor in
            guard await panel.presentForKeyWindow() == .OK else { return }
            add(panel.urls)
        }
    }

    /// The button's and a drop's one way in. What the items are is read off the main actor (`FolderDrop.look`,
    /// within its 10 s deadline, L157); the rule is then applied to the list as it is by then.
    private func add(_ urls: [URL]) {
        Task { @MainActor in
            let look = await FolderDrop.look(at: urls)
            let outcome = FolderDrop.addingExclusions(look.items, to: exclusions)
            exclusions = outcome.list
            addProblem = outcome.problem
        }
    }

    /// The selected rows but Restorey's own folders, which always stay.
    private func remove(own: Set<String>) {
        exclusions.removeAll { selection.contains($0) && !own.contains($0) }
        selection = []
        addProblem = nil
    }
}
