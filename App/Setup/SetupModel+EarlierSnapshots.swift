import Foundation
import RestoreyCore

/// The adoption step's opt-in (UI design §4 step 3, product spec §5.6, Task 14b): "Apply this plan's retention to
/// existing snapshots from this Mac", off by default. Choosing it previews (a `forget --dry-run` the agent runs without
/// a lock, recording nothing) and asks with its own confirmation, counting exactly the snapshots that would go. The
/// confirmed IDs are kept in the progress (`SetupProgress.earlierRemoval`); Done hands them to the agent, which removes
/// them only after the plan's first successful backup, so a setup that fails never deletes anything.
extension SetupModel {
    /// The confirmed choice, or nil (off).
    var earlierRemoval: EarlierSnapshotsConfirmation? { draft.progress.earlierRemoval }

    /// The `.ready` step's switch, for a repository this setup adopted: on asks again, off forgets the choice.
    func switchEarlierRemoval(_ on: Bool) async {
        guard step == .password, draft.progress.adoption != nil, let plan = draft.plan else { return }
        guard on else {
            recordEarlierRemoval(nil)
            earlierNote = nil
            return
        }
        await act { await chooseEarlierRemoval(plan) }
    }

    /// Previews the adopted, pre-filled plan's snapshots from before Restorey and asks. Returns the sentence of a
    /// failure, or nil. Nothing to remove, or Cancel, leaves the choice off and says so (`earlierNote`).
    func chooseEarlierRemoval(_ plan: Plan) async -> String? {
        guard let supervisor else { return nil }
        switch await supervisor.connection.previewEarlierSnapshots(plan.id) {
        case .failure(let error):
            recordEarlierRemoval(nil)
            return error.description
        case .success(let preview):
            guard let group = preview.group(.beforeAdoption), !group.removeIDs.isEmpty else {
                recordEarlierRemoval(nil)
                earlierNote = "None of this Mac's snapshots from before Restorey are beyond this plan's retention, so none will be removed."
                return nil
            }
            let text = EarlierSnapshotsText.confirmation(group, pruneEnabled: plan.pruneEnabled, afterFirstBackup: true)
            if await DestructiveConfirmation.ask(text) {
                recordEarlierRemoval(EarlierSnapshotsConfirmation(group))
                earlierNote = nil
            } else {
                recordEarlierRemoval(nil)
                earlierNote = "Nothing from before Restorey will be removed."
            }
            return nil
        }
    }

    /// Done's line about the choice, or nil when it is off.
    var earlierRemovalSummary: String? {
        guard let choice = earlierRemoval else { return nil }
        let n = choice.snapshotIDs.count
        return "After the first backup succeeds, Restorey removes the \(n) \(n == 1 ? "snapshot" : "snapshots") from before Restorey you confirmed."
    }
}
