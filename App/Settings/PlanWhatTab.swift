import RestoreyCore
import SwiftUI

/// A plan's What tab (UI design §6.2): its name, the folders and drives it backs up, and what it leaves out
/// (setup's one line and "Review Exclusions…" sheet). A different list of folders shows the product spec's
/// new-group warning (§5.6).
struct PlanWhatTab: View {
    @Bindable var model: PlanEditModel
    let identity: Identity
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupField(label: "Name", problem: model.edit.nameProblem) {
                PlainTextField(title: "Name", text: $model.fields.name)
            }
            SetupField(label: "Folders and drives", problem: model.edit.sourcesProblem) {
                SourcesEditor(sources: $model.fields.sources)
            }
            if let warning = model.edit.sourcesWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(ExclusionsSummary.line(plan: shown, home: Self.home, identity: identity))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review Exclusions…") { reviewing = true }
            }
        }
        .sheet(isPresented: $reviewing) {
            ExclusionsSheet(
                exclusions: $model.fields.exclusions, fileTypes: $model.fields.fileTypeExclusions,
                oneFileSystem: $model.fields.oneFileSystem, home: Self.home, identity: identity)
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

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
