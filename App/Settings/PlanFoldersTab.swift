import RestoreyCore
import SwiftUI

/// A plan's Folders tab (UI design §6.2; "What" until Task 17c): its name, the folders and drives it backs up, and what
/// it leaves out (setup's one line and "Review Exclusions…" sheet, then the items apps mark as not for backup, counted
/// from a fresh Spotlight look, with "Show…"), as a grouped form. A different list of folders shows the product spec's
/// new-group warning (§5.6).
struct PlanFoldersTab: View {
    @Bindable var model: PlanEditModel
    let identity: Identity
    /// The agent's last Full Disk Access probe: without it the app's own look can't read the attribute in protected
    /// folders, so the line and the sheet say the list may be incomplete.
    let fullDiskAccessMissing: Bool
    @State private var reviewing = false
    @State private var showingMarked = false
    /// The latest look for marked items in the sources as edited; nil while it runs.
    @State private var marked: MarkedItemsScan.Result?
    /// Bumped when the sheet closes, so the count is looked up again.
    @State private var markedLookups = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    PlainTextField(title: "Name", text: $model.fields.name)
                }
                if let problem = model.edit.nameProblem { SeverityText(problem) }
            }
            Section("Folders and drives") {
                SourcesEditor(sources: $model.fields.sources, repository: model.saved.repository)
                if let problem = model.edit.sourcesProblem { SeverityText(problem) }
                if let warning = model.edit.sourcesWarning {
                    SeverityText(warning, severity: .warning)
                }
            }
            Section {
                LabeledContent {
                    Button("Review Exclusions…") { reviewing = true }
                } label: {
                    Text(ExclusionsSummary.line(plan: shown, home: Self.home, identity: identity, mentionsMarkedItems: false))
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent {
                    Button("Show…") { showingMarked = true }
                        .accessibilityLabel("Show items apps mark as not for backup")
                } label: {
                    Text(MarkedNotForBackupText.line(
                        count: markedCount, skips: model.fields.skipsItemsMarkedNotForBackup, locale: .current))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                if model.fields.skipsItemsMarkedNotForBackup,
                    let note = MarkedNotForBackupText.incompleteNote(fullDiskAccessMissing: fullDiskAccessMissing)
                {
                    Text(note).explanatoryNote()
                }
            }
        }
        .formStyle(.grouped)
        .task(id: MarkedLookup(sources: model.fields.sources, generation: markedLookups)) {
            marked = nil
            marked = await MarkedItemsScan.offPool(finder: SpotlightMarkedItems(), sources: model.fields.sources)
        }
        .sheet(isPresented: $showingMarked, onDismiss: { markedLookups += 1 }) {
            NotForBackupSheet(
                skips: $model.fields.skipsItemsMarkedNotForBackup, backUpAnyway: $model.fields.backUpAnyway,
                sources: model.fields.sources, exclusions: model.fields.exclusions, home: Self.home,
                fullDiskAccessMissing: fullDiskAccessMissing)
        }
        .sheet(isPresented: $reviewing) {
            ExclusionsSheet(
                exclusions: $model.fields.exclusions, fileTypes: $model.fields.fileTypeExclusions,
                oneFileSystem: $model.fields.oneFileSystem, home: Self.home, identity: identity,
                repository: model.saved.repository, sources: model.fields.sources)
        }
    }

    /// The plan with the exclusions as edited, for the summary line.
    private var shown: Plan {
        var plan = model.saved
        plan.exclusions = model.fields.exclusions
        plan.fileTypeExclusions = model.fields.fileTypeExclusions
        plan.oneFileSystem = model.fields.oneFileSystem
        return plan
    }

    /// How many marked items a backup would skip with the fields as edited; nil while looking or when the look gave up.
    private var markedCount: Int? {
        guard case .found(let verified) = marked else { return nil }
        return MarkedItemsList.skippedCount(
            verified: verified, sources: model.fields.sources, exclusions: model.fields.exclusions,
            backUpAnyway: model.fields.backUpAnyway)
    }

    private struct MarkedLookup: Equatable {
        var sources: [String]
        var generation: Int
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
