import RestoreyCore
import SwiftUI

/// Setup step 5, "What to back up" (mockup step 5, UI design §4): the home folder by default (or, for an
/// adopted repository, the latest snapshot's folders), add folders or drives, and what is left out summed up
/// in one line with "Review exclusions…" (folders, file types, one file system: product spec §5.7). Continue
/// saves the plan, which stays unfinished, so nothing runs yet.
struct SourcesView: View {
    @Bindable var model: SetupModel
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SourcesEditor(sources: $model.sources, repository: model.plan?.repository)
                .disabled(model.working)
            if let problem = model.sourcesProblem {
                SeverityText(problem)
            }
            if let warning = model.sourcesWarning {
                SeverityText(warning, severity: .warning)
            }
            if let plan = model.plan, let identity = model.identity {
                HStack(alignment: .firstTextBaseline) {
                    Text(ExclusionsSummary.line(plan: plan, home: Self.home, identity: identity))
                        .explanatoryNote()
                    Button("Review Exclusions…") { reviewing = true }
                        .disabled(model.working)
                }
            }
            SetupStepStatus(model: model)
            Spacer(minLength: 12)
            SetupButtonRow {
                if model.working { ProgressView().controlSize(.small) }
                Button("Continue") { Task { await model.continueFromSources() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.plan == nil || model.sourcesProblem != nil)
            }
        }
        .task { await model.loadPlan() }
        .sheet(isPresented: $reviewing) {
            if let identity = model.identity {
                ExclusionsSheet(
                    exclusions: $model.exclusions, fileTypes: $model.fileTypeExclusions,
                    oneFileSystem: $model.oneFileSystem, home: Self.home, identity: identity,
                    repository: model.plan?.repository, sources: model.sources)
            }
        }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
