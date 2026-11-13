import RestoreyCore
import SwiftUI

/// "Restore Files…" in v0.1 (UI design §5; the restore window is v0.2): the plan's restic commands, as the
/// recovery kit's "Restore without Restorey" has them, with a copy button each. Passwords and keys show as dots;
/// "Show Passwords and Keys" keeps them shown and holding Option shows them while held (`OptionKeyMonitor`), after
/// Touch ID or the login password once per opening (`RestoreFilesModel`).
struct RestoreFilesView: View {
    let model: RestoreFilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.plans.isEmpty {
                Text(model.statusKnown ? "No plan has finished setup yet, so there's nothing to restore." : "Waiting for Restorey's background agent…")
                    .foregroundStyle(.secondary)
            } else {
                if model.plans.count > 1 || model.plan == nil {
                    Picker("Plan", selection: Binding(get: { model.planID }, set: { model.planID = $0 })) {
                        ForEach(model.plans) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                }
                if model.plan != nil {
                    commands
                } else {
                    Text("Pick a plan.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 600, alignment: .topLeading)
        .frame(minHeight: 240, alignment: .topLeading)
        .background(OptionKeyMonitor(onChange: { model.optionChanged($0) }, onResignKey: { model.resignedKey() }))
    }

    @ViewBuilder private var commands: some View {
        Text("Restorey's restore window comes in a later version. Until then, restic restores this plan's files from Terminal: install restic (restic.net), then paste these in order. The files go to a folder called Restored in your home folder.")
            .fixedSize(horizontal: false, vertical: true)
        ForEach(model.commands) { command in
            VStack(alignment: .leading, spacing: 4) {
                Text(command.title).font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Text(model.revealed ? command.revealedText : command.text)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    Button(model.copied == command.title ? "Copied" : "Copy") { let title = command.title; Task { await model.copy(title) } }
                        .disabled(model.working)
                        .accessibilityLabel("Copy \(command.title)")
                }
            }
        }
        HStack(spacing: 8) {
            if model.working { ProgressView().controlSize(.small) }
            Text("Hold Option for a quick look at the passwords and keys. Copy puts the real command on the clipboard.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(model.reveal.buttonTitle(authenticated: model.authenticated)) {
                Task { await model.revealButtonPressed() }
            }
            .disabled(model.working)
        }
        if let problem = model.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
