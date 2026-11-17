import AppKit
import RestoreyCore
import SwiftUI

/// The files a warning backup couldn't read (Task 16b, owner 17 Nov 2026), from the Overview's and History's "Show…":
/// each one with why in plain words, and "Don't back this up" where there is something to exclude. The button adds
/// the path's exclusion pattern (`DefaultExclusions.pattern(forFolder:)`) to the plan's fields, so saving, Revert and
/// the close and quit guard are the plan editor's, as in `NotForBackupSheet`. Information only: nothing here changes
/// the backup's outcome, the icon, an alert or a ping.
struct UnreadableFilesSheet: View {
    let summary: UnreadableSummary
    @Bindable var model: PlanEditModel
    @Environment(\.dismiss) private var dismiss

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        let rows = UnreadableList.rows(
            items: summary.items, exclusions: model.fields.exclusions, saved: model.saved.exclusions, home: home,
            exists: { FileManager.default.fileExists(atPath: $0) })
        VStack(alignment: .leading, spacing: 12) {
            Text("Files that couldn't be read").font(.title3.bold())
            List {
                ForEach(rows) { row in
                    RowView(row: row, add: { add(row) }, undo: { undo(row) })
                }
                if let more = UnreadableList.moreLine(count: summary.count, listed: summary.items.count) {
                    Text(more).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 200, idealHeight: 280)
            .accessibilityLabel("Files that couldn't be read")
            Text("You can change this later in What → Review Exclusions…")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rows.contains(where: { $0.action == .excluded(unsaved: true) }) {
                Text("Save the plan's changes to apply this.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func add(_ row: UnreadableList.Row) {
        model.fields.exclusions = UnreadableList.adding(row.path, to: model.fields.exclusions)
    }

    private func undo(_ row: UnreadableList.Row) {
        model.fields.exclusions = UnreadableList.removing(row.path, from: model.fields.exclusions)
    }

    private struct RowView: View {
        let row: UnreadableList.Row
        let add: () -> Void
        let undo: () -> Void

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.display).lineLimit(1).truncationMode(.middle).help(row.path)
                    Text(row.reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.canOpenInFinder {
                    Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
                        .buttonStyle(.link)
                        .accessibilityLabel("Open \(row.display) in Finder")
                }
                switch row.action {
                case .dontBackUp:
                    Button("Don't back this up", action: add)
                        .accessibilityLabel("Don't back up \(row.display)")
                case .excluded(let unsaved):
                    Text(unsaved ? "Won't be backed up from the next backup" : "Already not backed up")
                        .font(.caption).foregroundStyle(.secondary)
                    if unsaved { Button("Undo", action: undo).buttonStyle(.link) }
                case .none:
                    EmptyView()
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
