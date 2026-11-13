import AppKit
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
            SourcesEditor(sources: $model.sources)
                .disabled(model.working)
            if let problem = model.sourcesProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if let warning = model.sourcesWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan = model.plan, let identity = model.identity {
                HStack(alignment: .firstTextBaseline) {
                    Text(ExclusionsSummary.line(plan: plan, home: Self.home, identity: identity))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                ExclusionsSheet(model: model, home: Self.home, identity: identity)
            }
        }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

/// What the plan leaves out: folders (restic patterns; Restorey's own folders stay), file types, and
/// whether other file systems mounted inside a source are skipped.
private struct ExclusionsSheet: View {
    @Bindable var model: SetupModel
    let home: URL
    let identity: Identity
    @State private var selection: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let own = Set(DefaultExclusions.ownFolders(home: home, identity: identity))
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclusions").font(.title3.bold())
            Text("Folders").font(.headline)
            List(selection: $selection) {
                ForEach(model.exclusions, id: \.self) { pattern in
                    HStack {
                        Text(DefaultExclusions.displayPattern(pattern, home: home))
                            .lineLimit(1).truncationMode(.middle)
                        if own.contains(pattern) {
                            Spacer()
                            Text("Restorey's own").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(pattern)
                    .tag(pattern)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 140, idealHeight: 180)
            .accessibilityLabel("Folders left out")
            HStack {
                Button("Add Folder…", action: addFolder)
                Button("Remove") {
                    model.exclusions.removeAll { selection.contains($0) && !own.contains($0) }
                    selection = []
                }
                .disabled(selection.subtracting(own).isEmpty)
            }
            Text("File types").font(.headline)
            FileTypesEditor(types: $model.fileTypeExclusions)
            Toggle("Skip other file systems mounted inside these folders", isOn: $model.oneFileSystem)
            Text("Such as a network share or a connected iPhone. A drive you add as a source is still backed up.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("iCloud files that aren't on this Mac are always skipped.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Leave Out"
        panel.message = "Choose the folders to leave out of the backup."
        Task { @MainActor in
            guard await panel.begin() == .OK else { return }
            for url in panel.urls {
                let pattern = DefaultExclusions.pattern(forFolder: url.path)
                if !model.exclusions.contains(pattern) { model.exclusions.append(pattern) }
            }
        }
    }
}
