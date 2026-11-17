import RestoreyCore
import SwiftUI

/// Items apps mark as not for backup (Task 15c, product spec §5.7), as a sheet from the What tab's "Show…": whether the
/// plan skips them, and each one a backup would skip, with "Back up anyway". The list comes from a fresh look run here
/// (`MarkedItemsScan.offPool`, the agent's own scan and collapse), so it matches what the next backup leaves out.
/// Sizes aren't shown: measuring them would mean walking every folder. Edits go into the plan's fields, so saving,
/// Revert and the close and quit guard are the What tab's.
struct NotForBackupSheet: View {
    @Binding var skips: Bool
    @Binding var backUpAnyway: [String]
    let sources: [String]
    let exclusions: [String]
    let home: URL
    let fullDiskAccessMissing: Bool
    @State private var result: MarkedItemsScan.Result?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Items marked not for backup").pageTitle()
            Toggle("Skip items apps mark as not for backup", isOn: $skips)
            Text("Apps and macOS mark data they can rebuild, such as caches, previews and virtual machine "
                + "disks, so Time Machine leaves it out. Restorey does the same. Anything Spotlight can’t see is backed up.")
                .explanatoryNote()
            if let note = MarkedNotForBackupText.incompleteNote(fullDiskAccessMissing: fullDiskAccessMissing) {
                Text(note).explanatoryNote()
            }
            list
                .frame(minHeight: 200, idealHeight: 260)
                .disabled(!skips)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .dismissesOnEscape()
        .frame(width: 560)
        .task { result = await MarkedItemsScan.offPool(finder: SpotlightMarkedItems(), sources: sources) }
    }

    @ViewBuilder private var list: some View {
        switch result {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gaveUp, .busy:
            Text("Spotlight didn’t answer in time, so the list can’t be shown now. A backup that can’t check includes these items.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .found(let verified):
            let rows = MarkedItemsList.rows(
                verified: verified, sources: sources, exclusions: exclusions, backUpAnyway: backUpAnyway, home: home)
            if rows.isEmpty {
                Text("Nothing in these folders is marked not for backup.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(rows) { row in
                    HStack {
                        Text(row.display).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Toggle("Back up anyway", isOn: backedUpAnyway(row))
                            .toggleStyle(.checkbox)
                            // Backed up by an entry for a folder above it, which unticking this row can't change.
                            .disabled(row.coveredByEntryAbove)
                            .accessibilityLabel("Back up \(row.display) anyway")
                    }
                    .help(row.coveredByEntryAbove ? "\(row.path)\nBacked up because a folder above it is." : row.path)
                }
                .listStyle(.bordered)
                .accessibilityLabel("Items marked not for backup")
            }
        }
    }

    /// The row was built from the current entries, so its value is current; a change rebuilds the rows.
    private func backedUpAnyway(_ row: MarkedItemsList.Row) -> Binding<Bool> {
        Binding(
            get: { row.backedUpAnyway },
            set: { backUpAnyway = MarkedItemsList.settingBackUpAnyway($0, for: row.path, in: backUpAnyway) })
    }
}
