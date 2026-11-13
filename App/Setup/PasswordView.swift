import AppKit
import RestoreyCore
import SwiftUI

/// Setup step 3, "Repository password" (mockup step 3, UI design §4), decided by what "Check" found:
/// nothing there, so a generated password (or the user's own) and an explicit "Create new repository" (never
/// automatic, product spec §5.4); or a repository already there, so its password, then "312 snapshots from
/// 3 Macs", the host label its snapshots are under with the new-group warning, and "Use this repository".
struct PasswordView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.draft.probe?.state {
            case nil:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking the repository address…").foregroundStyle(.secondary)
                }
            case .empty?:
                NewRepositoryForm(model: model)
            case .passwordRejected?:
                ExistingRepositoryPassword(model: model)
            case .existing(let report)?:
                ExistingRepositorySummary(model: model, report: report)
            }
            SetupStepStatus(model: model)
            Spacer(minLength: 12)
            HStack {
                Button("Back") { model.backToStorage() }
                    .disabled(model.working || model.repositoryReady)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                actionButton
            }
        }
        .task {
            await model.loadPlan()
            await model.probeIfNeeded()
        }
    }

    @ViewBuilder private var actionButton: some View {
        if model.repositoryReady {
            Button("Continue") { model.continueFromPassword() }
                .keyboardShortcut(.defaultAction)
        } else {
            switch model.draft.probe?.state {
            case .empty?:
                Button("Create New Repository") { Task { await model.createRepository() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.passwordProblem != nil)
            case .passwordRejected?:
                Button("Open Repository") { Task { await model.openExistingRepository() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.secret(.repositoryPassword(model.planID)).isEmpty)
            case .existing?:
                Button("Use This Repository") { Task { await model.useExistingRepository() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || FormValidation.hostLabel(model.hostLabel) != nil)
            case nil:
                EmptyView()
            }
        }
    }
}

/// Nothing at the address: the generated password, shown and copyable, or the user's own.
private struct NewRepositoryForm: View {
    @Bindable var model: SetupModel

    var body: some View {
        let key = SecretKey.repositoryPassword(model.planID)
        Text("Nothing here yet.").font(.headline)
        Text("Restorey makes a new repository here, locked with this password. You need the password to restore, so it goes in the recovery kit next.")
            .fixedSize(horizontal: false, vertical: true)
        Picker("Password", selection: Binding(get: { model.ownPassword }, set: { model.chooseOwnPassword($0) })) {
            Text("Generated password").tag(false)
            Text("My own password").tag(true)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(model.working)
        SetupField(label: model.ownPassword ? "Your password" : "New password") {
            HStack {
                SecretField(title: "Repository password", text: secret(key))
                if !model.ownPassword {
                    Button("Copy") { copyConcealed(model.secret(key)) }
                    Button("New") { model.newGeneratedPassword() }
                        .help("Make another password")
                }
            }
        }
        .disabled(model.working)
        .onAppear { if !model.ownPassword { model.offerGeneratedPassword() } }
        if !model.ownPassword {
            Text("Six random words: about 77 bits, as strong as 13 random letters and digits, and easier to read out.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func secret(_ key: SecretKey) -> Binding<String> {
        Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) })
    }
}

/// A repository is there and the stand-in password didn't open it: ask for its own.
private struct ExistingRepositoryPassword: View {
    @Bindable var model: SetupModel

    var body: some View {
        let key = SecretKey.repositoryPassword(model.planID)
        Text("A repository is already here.").font(.headline)
        Text("Enter its password to use it. Your folders come from the latest snapshot for this Mac.")
            .fixedSize(horizontal: false, vertical: true)
        SetupField(label: "Repository password") {
            SecretField(
                title: "Repository password",
                text: Binding(get: { model.secret(key) }, set: { model.setSecret($0, for: key) }))
        }
        .disabled(model.working)
    }
}

/// The password opened it: what's there, and which host label this Mac's snapshots are under.
private struct ExistingRepositorySummary: View {
    @Bindable var model: SetupModel
    let report: AdoptReport

    var body: some View {
        if model.repositoryReady {
            Text("The repository is ready.").font(.headline)
        } else {
            Text("A repository is already here: \(SetupAdoption.summary(report)).").font(.headline)
            Text("Restorey adds this Mac's backups to it and never removes snapshots it didn't make. It doesn't prune an existing repository, which locks out other Macs while it runs; you can turn pruning on in Settings.")
                .fixedSize(horizontal: false, vertical: true)
            SetupField(label: "This Mac's snapshots are under") {
                Picker("Host label", selection: $model.hostLabel) {
                    ForEach(model.hostChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(model.working)
            if let warning = SetupAdoption.newGroupWarning(hostLabel: model.hostLabel, sources: nil, report: report) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Copies a secret the user asked to copy, marked concealed so clipboard managers that honour the marker
/// (nspasteboard.org) don't keep it.
@MainActor
private func copyConcealed(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
}
