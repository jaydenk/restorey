import RestoreyCore
import SwiftUI

/// The recovery kit itself (UI design §7), in setup's step 4 and in the kit window: each field with a copy button
/// (secrets as dots until "Show Passwords and Keys", or while Option is held; copied as concealed pasteboard items),
/// then Print… and Save as PDF…, in the
/// order the spec offers them. Saving to this Mac's own disk shows the warning to delete the copy once the kit is
/// stored elsewhere.
struct RecoveryKitView: View {
    let model: RecoveryKitModel
    private var showSecrets: Bool { model.reveal.visible }

    var body: some View {
        switch model.state {
        case .idle, .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Getting the recovery kit…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        case .failed(let sentence):
            VStack(alignment: .leading, spacing: 8) {
                Label(sentence, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Without every key the kit can't open the repository, so Restorey doesn't show part of one.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded(let document):
            loaded(document)
                .background(OptionKeyMonitor(onChange: { model.optionChanged($0) }, onResignKey: { model.resignedKey() }))
        }
    }

    @ViewBuilder private func loaded(_ document: RecoveryKitDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(document.sections) { section in
                        SectionView(section: section, showSecrets: showSecrets, copied: model.copied) { model.copy($0) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, idealHeight: 300, maxHeight: 340)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(model.reveal.buttonTitle(authenticated: true)) { model.toggleReveal() }
                Spacer()
                Button("Print…") { model.print() }
                Button("Save as PDF…") { model.savePDF() }
            }
            if let error = model.exportError {
                Label(FormValidation.sentence(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.savedOnThisMac != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label(RecoveryKitLocation.internalDiskWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show in Finder") { model.showSavedCopyInFinder() }
                }
            }
        }
    }
}

private struct SectionView: View {
    let section: RecoveryKitDocument.Section
    let showSecrets: Bool
    let copied: String?
    let copy: (RecoveryKitDocument.Field) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title).font(.headline)
            if section.title == RecoveryKitText.restoreSection {
                Text(RecoveryKitText.restoreIntro)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(section.fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                        Text(field.isSecret && !showSecrets ? field.concealed : field.value)
                            .font(.system(.callout, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(copied == field.label ? "Copied" : "Copy") { copy(field) }
                        .controlSize(.small)
                        .accessibilityLabel("Copy \(field.label)")
                }
            }
        }
    }
}
