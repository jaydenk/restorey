import RestoreyCore
import SwiftUI

/// The Retention tab's "Earlier snapshots", a section of its form (UI design §6.2, Task 14b; product spec §5.6): from a preview (a `forget
/// --dry-run` the agent runs without a lock, recording nothing), how many snapshots each earlier group of the plan
/// holds — its previous folder lists and, for an adopted plan, the snapshots from before Restorey — with "Apply
/// Retention…" for each one retention would thin. The button asks first (`DestructiveConfirmation`); only what that
/// confirmation counted can be removed.
///
/// The preview runs when the tab appears and again when the saved sources, host label or retention change (a save),
/// never on a redraw. It counts with the saved plan, so while the tab has unsaved edits the buttons wait for a save.
struct EarlierSnapshotsSection: View {
    let plan: Plan
    let unsavedEdits: Bool
    let connection: AgentConnection

    @State private var preview: EarlierSnapshotsPreview?
    /// The preview's failure.
    @State private var problem: String?
    /// The removal's failure, kept across the preview that follows it.
    @State private var removalProblem: String?
    @State private var outcome: String?
    @State private var working = false

    /// What the preview depends on.
    private struct Inputs: Equatable {
        var id: UUID
        var hostLabel: String
        var sources: [String]
        var retention: Retention
    }

    private var inputs: Inputs {
        Inputs(id: plan.id, hostLabel: plan.hostLabel, sources: plan.sources, retention: plan.retention)
    }

    var body: some View {
        Section {
            content
            if let outcome {
                Text(outcome).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = removalProblem ?? problem {
                SeverityText(problem)
            }
            if problem != nil {
                Button("Try Again") { Task { await load() } }
                    .disabled(working)
            }
        } header: {
            Text("Earlier snapshots")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.origin == .adopted
                     ? "Retention never thins this Mac’s snapshots from before Restorey, or those of a previous folder list, unless you apply it here."
                     : "Retention never thins the snapshots of a previous folder list unless you apply it here.")
                    .explanatoryNote()
                if unsavedEdits, let preview, EarlierSnapshotsText.nothingToApply(preview) == nil {
                    Text("These are counted with the saved settings. Save your changes to count them again.")
                        .explanatoryNote()
                }
            }
        }
        .task(id: inputs) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let preview {
            if let line = EarlierSnapshotsText.nothingToApply(preview) {
                Text(line).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(preview.groups.filter { !$0.removeIDs.isEmpty }, id: \.scope) { group in
                    LabeledContent {
                        Button("Apply Retention…") { Task { await apply(group) } }
                            .disabled(working || unsavedEdits)
                    } label: {
                        Text(EarlierSnapshotsText.row(group)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if problem == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("Counting earlier snapshots…").foregroundStyle(.secondary)
            }
        }
    }

    /// `keepingRemovalProblem`: the preview right after a failed removal, which mustn't hide why it failed. A later
    /// preview that succeeds (Try Again, a save, coming back to the tab) clears it.
    private func load(keepingRemovalProblem: Bool = false) async {
        problem = nil
        switch await connection.previewEarlierSnapshots(plan.id) {
        case .success(let found):
            preview = found
            if !keepingRemovalProblem { removalProblem = nil }
        case .failure(let error):
            preview = nil
            problem = FormValidation.sentence(error.description)
        }
    }

    private func apply(_ group: EarlierSnapshotGroup) async {
        let text = EarlierSnapshotsText.confirmation(group, pruneEnabled: plan.pruneEnabled, afterFirstBackup: false)
        guard await DestructiveConfirmation.ask(text) else { return }
        working = true
        outcome = nil
        removalProblem = nil
        defer { working = false }
        let request = EarlierSnapshotsRequest(planID: plan.id, confirmation: EarlierSnapshotsConfirmation(group))
        switch await connection.removeEarlierSnapshots(request) {
        case .success(let removal): outcome = EarlierSnapshotsText.removed(removal)
        case .failure(let error): removalProblem = FormValidation.sentence(error.description)
        }
        await load(keepingRemovalProblem: true)
    }
}
