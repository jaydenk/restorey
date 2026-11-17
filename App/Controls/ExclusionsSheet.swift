import AppKit
import RestoreyCore
import SwiftUI

/// What a plan leaves out, as a sheet (setup's sources step and Settings' Folders tab): folders (restic patterns;
/// Restorey's own folders stay), file types, and whether other file systems mounted inside a source are skipped.
struct ExclusionsSheet: View {
    @Binding var exclusions: [String]
    @Binding var fileTypes: [String]
    @Binding var oneFileSystem: Bool
    let home: URL
    let identity: Identity
    @State private var selection: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let own = Set(DefaultExclusions.ownFolders(home: home, identity: identity))
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclusions").pageTitle()
            Text("Folders").font(.headline)
            List(selection: $selection) {
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
            HStack {
                Button("Add Folder…", action: addFolder)
                Button("Remove") {
                    exclusions.removeAll { selection.contains($0) && !own.contains($0) }
                    selection = []
                }
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

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Leave Out"
        panel.message = "Choose the folders to leave out of the backup."
        Task { @MainActor in
            guard await panel.presentForKeyWindow() == .OK else { return }
            for url in panel.urls {
                let pattern = DefaultExclusions.pattern(forFolder: url.path)
                if !exclusions.contains(pattern) { exclusions.append(pattern) }
            }
        }
    }
}
