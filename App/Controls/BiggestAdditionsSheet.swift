import AppKit
import RestoreyCore
import SwiftUI

/// What a backup added the most (Task 16d, owner 17 Nov 2026), from History's and the Overview's "Show…": the biggest
/// files and the folders whose files together added the most, each with its size in the repository after compression,
/// and Open in Finder while the path still exists. Information only: nothing here changes a plan, an outcome, the icon,
/// an alert or a ping.
struct BiggestAdditionsSheet: View {
    let additions: BiggestAdditions
    @Environment(\.dismiss) private var dismiss

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let files = BiggestAdditionsText.rows(additions.files, home: home, locale: .current, exists: exists)
        let folders = BiggestAdditionsText.rows(additions.folders, home: home, locale: .current, exists: exists)
        VStack(alignment: .leading, spacing: 12) {
            Text("Biggest additions").font(.title3.bold())
            Text(BiggestAdditionsText.caption(additions, locale: .current))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                Section("Files") {
                    ForEach(files) { RowView(row: $0) }
                }
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { RowView(row: $0) }
                        if additions.foldersIncomplete {
                            Text(BiggestAdditionsText.foldersIncompleteNote)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 260, idealHeight: 340)
            .accessibilityLabel("Biggest additions")
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private struct RowView: View {
        let row: BiggestAdditionsText.Row

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.display).lineLimit(1).truncationMode(.middle).help(row.path)
                Spacer()
                Text(row.size).monospacedDigit().foregroundStyle(.secondary)
                if row.canOpenInFinder {
                    Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
                        .buttonStyle(.link)
                        .accessibilityLabel("Open \(row.display) in Finder")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
