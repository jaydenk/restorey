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
            switch model.passwordStep {
            case .probing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking the repository address…").foregroundStyle(.secondary)
                }
            case .probeFailed:
                Text("Restorey couldn’t check the repository address.").font(.headline)
                Text("Try again, or go back and check the address.")
                    .fixedSize(horizontal: false, vertical: true)
            case .create:
                NewRepositoryForm(model: model)
            case .open:
                ExistingRepositoryPassword(model: model)
            case .adopt(let report):
                ExistingRepositorySummary(model: model, report: report)
            case .ready:
                Text("The repository is ready.").font(.headline)
                // From what the progress records, not from what the step last said.
                Text(model.draft.progress.adoption != nil
                     ? "This setup has adopted it. Continue to the recovery kit."
                     : model.draft.progress.repositoryCreated
                     ? "This setup created it. Continue to the recovery kit."
                     : "This setup made or adopted it before it was interrupted. Continue to the recovery kit.")
                    .fixedSize(horizontal: false, vertical: true)
                if model.draft.progress.adoption != nil {
                    EarlierSnapshotsOptIn(model: model, isOn: Binding(
                        get: { model.earlierRemoval != nil },
                        set: { on in Task { await model.switchEarlierRemoval(on) } }))
                }
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
        switch model.passwordStep {
        case .ready:
            Button("Continue") { model.continueFromPassword() }
                .keyboardShortcut(.defaultAction)
        case .create:
            Button("Create New Repository") { Task { await model.createRepository() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.working || model.passwordProblem != nil)
        case .open:
            Button("Open Repository") { Task { await model.openExistingRepository() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.working || model.secret(.repositoryPassword(model.planID)).isEmpty)
        case .adopt:
            Button("Use This Repository") { Task { await model.useExistingRepository() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.working || FormValidation.hostLabel(model.hostLabel) != nil)
        case .probeFailed:
            Button("Try Again") { Task { await model.probeIfNeeded() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.working)
        case .probing:
            EmptyView()
        }
    }
}

/// Nothing at the address: the generated password, shown and copyable, or the user's own.
/// Under a field where the person types a repository password: the field is secure, which hides what an accent key
/// (a dead key) has done, so Show is how to check it.
private let accentsHint = "To type accented letters, turn on Show."

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
        // An empty field only disables the button; a password with a space at an end gets its sentence.
        SetupField(
            label: model.ownPassword ? "Your password" : "New password",
            problem: model.secret(key).isEmpty ? nil : model.passwordProblem
        ) {
            HStack {
                SecretField(title: "Repository password", text: secret(key))
                if !model.ownPassword {
                    Button("Copy") { ConcealedPasteboard.copy(model.secret(key)) }
                    Button("New") { model.newGeneratedPassword() }
                        .help("Make another password")
                }
            }
        }
        .disabled(model.working)
        .onAppear { if !model.ownPassword { model.offerGeneratedPassword() } }
        if !model.ownPassword {
            Text("Six random words: about 77 bits, as strong as 13 random letters and digits, and easier to read out.")
                .explanatoryNote()
        } else {
            Text(accentsHint).explanatoryNote()
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
        Text(accentsHint).explanatoryNote()
    }
}

/// The password opened it: what's there, and which host label this Mac's snapshots are under.
private struct ExistingRepositorySummary: View {
    @Bindable var model: SetupModel
    let report: AdoptReport

    var body: some View {
        Text("A repository is already here: \(SetupAdoption.summary(report)).").font(.headline)
        Text("Restorey adds this Mac’s backups to it and never removes snapshots it didn’t make. It doesn’t prune an existing repository, since that locks out other Macs; you can turn pruning on in Settings.")
            .fixedSize(horizontal: false, vertical: true)
        SetupField(label: "This Mac’s snapshots are under") {
            Picker("Host label", selection: $model.hostLabel) {
                ForEach(model.hostChoices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(model.working)
        if let warning = SetupAdoption.newGroupWarning(hostLabel: model.hostLabel, sources: nil, report: report) {
            SeverityText(warning, severity: .warning)
        }
        EarlierSnapshotsOptIn(model: model, isOn: $model.applyRetentionToEarlier)
    }
}

/// "Apply this plan's retention to existing snapshots from this Mac" (product spec §5.6, Task 14b): off by default,
/// and nothing goes without its own confirmation, which counts what would.
private struct EarlierSnapshotsOptIn: View {
    @Bindable var model: SetupModel
    let isOn: Binding<Bool>

    var body: some View {
        Toggle("Apply this plan’s retention to existing snapshots from this Mac", isOn: isOn)
            .disabled(model.working)
        Text(model.earlierRemoval.map {
            "You confirmed removing \($0.snapshotIDs.count) of them. They go after the first backup succeeds."
        } ?? "Off: this Mac’s snapshots from before Restorey are kept as they are. On, you’ll see how many would be removed before anything is.")
            .explanatoryNote()
        if let note = model.earlierNote {
            Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
