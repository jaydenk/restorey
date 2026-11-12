import AppKit
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
                    Text(Self.display(path))
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
            guard await panel.begin() == .OK else { return }
            sources = Self.adding(panel.urls.map(\.path), to: sources)
        }
    }

    private func remove() {
        sources.removeAll { selection.contains($0) }
        selection = []
    }

    /// `existing` followed by each new path that isn't already in it.
    static func adding(_ paths: [String], to existing: [String]) -> [String] {
        var result = existing
        for path in paths where !result.contains(path) { result.append(path) }
        return result
    }

    static func display(_ path: String) -> String { NSString(string: path).abbreviatingWithTildeInPath }
}
