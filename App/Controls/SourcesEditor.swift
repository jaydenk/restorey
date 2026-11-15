import AppKit
import RestoreyCore
import SwiftUI

/// The folders and drives a plan backs up: a bordered list with "Add Folder or Drive…" and "Remove".
/// Paths are stored as absolute paths (the agent refuses anything else); the list shows them with `~` for
/// the home folder.
struct SourcesEditor: View {
    @Binding var sources: [String]
    @State private var selection: Set<String> = []

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
            .onChange(of: sources) { selection.formIntersection(sources) }
            HStack {
                Button("Add Folder or Drive…", action: add)
                Button("Remove", action: remove)
                    .disabled(selection.isEmpty)
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose the folders and drives to back up."
        Task { @MainActor in
            guard await panel.presentForKeyWindow() == .OK else { return }
            sources = FormValidation.addingSources(panel.urls.map(\.path), to: sources)
        }
    }

    private func remove() {
        sources.removeAll { selection.contains($0) }
        selection = []
    }
}
