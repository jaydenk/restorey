import RestoreyCore
import SwiftUI

/// Settings → Plans (UI design §6.2, mockup `v0.1-settings.html`): the plans in a sidebar with "+ Add plan…", and
/// the selected plan's tabs. An unfinished plan offers "Finish Setup…" instead of tabs, since setup is still
/// editing it. The plan's edits live in one `PlanEditModel`, made afresh for each plan shown, so switching plans
/// (after "Discard Changes" when something is unsaved) or closing the window drops what was typed. It is held by
/// the window (`PlanEditorSlot`), not this pane, so going to General and back keeps unsaved edits.
struct PlansPane: View {
    let context: SettingsContext
    @Bindable var state: ShellState
    let slot: PlanEditorSlot
    /// A selection waiting on "Discard Changes" (nil inside: no plan).
    @State private var pendingSelection: UUID??
    @State private var finishFirst: FinishFirst?

    private struct FinishFirst {
        let progress: SetupProgress
        let name: String
    }

    /// The plan shown and whether it can be edited: a new editor is made when either changes.
    private struct EditorKey: Equatable {
        var planID: UUID?
        var editable: Bool
    }

    private var status: AgentStatus? { context.supervisor.lastKnownStatus }
    private var plans: [PlanStatus] { status?.configError == nil ? status?.plans ?? [] : [] }

    /// The plan asked for while it exists, otherwise the first.
    private var selectedID: UUID? {
        if let id = state.settingsPlanID, plans.contains(where: { $0.plan.id == id }) { return id }
        return plans.first?.plan.id
    }

    private var selected: PlanStatus? { plans.first { $0.plan.id == selectedID } }

    private var editorKey: EditorKey {
        EditorKey(planID: selectedID, editable: selected.map { $0.setupState != .unfinished } ?? false)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: editorKey, initial: true) { openEditor() }
        .onChange(of: selected?.plan) { if let plan = selected?.plan { slot.editor?.rebase(on: plan) } }
        .alert(
            "Discard your changes to “\(slot.editor?.saved.name ?? "")”?",
            isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let next = pendingSelection { state.settingsPlanID = next }
                pendingSelection = nil
            }
            Button("Keep Editing", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("They haven't been saved.")
        }
        .alert(
            "Finish setting up “\(finishFirst?.name ?? "")” first",
            isPresented: Binding(get: { finishFirst != nil }, set: { if !$0 { finishFirst = nil } }),
            presenting: finishFirst
        ) { pending in
            Button("Finish Setup…") { context.openSetup(pending.progress) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Restorey sets up one plan at a time. Finish that plan's setup, or delete it here, then add another.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedID }, set: choose)) {
                ForEach(plans, id: \.plan.id) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.plan.name).lineLimit(1)
                        switch plan.setupState {
                        case .unfinished: Text("Setup not finished").font(.caption).foregroundStyle(.orange)
                        case .needsNewKit: Text("New recovery kit needed").font(.caption).foregroundStyle(.orange)
                        case .complete: EmptyView()
                        }
                    }
                    .tag(UUID?.some(plan.plan.id))
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button("+ Add plan…", action: addPlan)
                    .buttonStyle(.borderless)
                    .disabled(status == nil || status?.configError != nil)
                Spacer()
            }
            .padding(8)
        }
    }

    /// A switch away from unsaved edits asks first.
    private func choose(_ id: UUID?) {
        guard let id, id != selectedID else { return }
        if slot.editor?.edit.isDirty == true {
            pendingSelection = .some(id)
        } else {
            state.settingsPlanID = id
        }
    }

    /// The selected plan's editor: the one already open for it is kept (the pane came back from another section),
    /// any other is closed.
    private func openEditor() {
        guard let selected, selected.setupState != .unfinished else {
            slot.replace(with: nil)
            return
        }
        if let editor = slot.editor, editor.planID == selected.plan.id {
            editor.rebase(on: selected.plan)
            return
        }
        slot.replace(with: PlanEditModel(plan: selected.plan, connection: context.supervisor.connection))
    }

    private func addPlan() {
        guard let start = context.addPlan() else { return }
        switch start {
        case .start(let progress), .resume(let progress):
            context.openSetup(progress)
        case .finishFirst(let progress, let name):
            finishFirst = FinishFirst(progress: progress, name: name)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let configError = status?.configError {
            // The menu's wording (`MenuPresentation`).
            Label("Restorey can't read its settings: \(configError)", systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        } else if status == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for Restorey's background agent…").foregroundStyle(.secondary)
            }
            .padding(16)
        } else if let selected {
            if selected.setupState == .unfinished {
                UnfinishedPlanView(plan: selected.plan, context: context) { state.settingsPlanID = nil }
            } else if let editor = slot.editor, editor.planID == selected.plan.id {
                PlanDetail(status: selected, model: editor, context: context, tab: $state.settingsPlanTab) {
                    state.settingsPlanID = nil
                }
                    .id(selected.plan.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No backup plans yet").font(.headline)
                Text("Add one to start backing up this Mac.").foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

/// A plan's tabs (UI design §6.2). Which one shows is `ShellState.settingsPlanTab`, so the menu's "No off-Mac
/// monitoring — Add…" can open Alerts.
enum PlanTab: String, CaseIterable, Identifiable {
    case what, schedule, storage, keep, alerts, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .what: "What"
        case .schedule: "Schedule"
        case .storage: "Storage"
        case .keep: "Keep"
        case .alerts: "Alerts"
        case .history: "History"
        }
    }
}

/// A plan that finished setup: its tabs, then Delete Plan… and Save.
private struct PlanDetail: View {
    let status: PlanStatus
    @Bindable var model: PlanEditModel
    let context: SettingsContext
    @Binding var tab: PlanTab
    let deleted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.plan.name).font(.title3.weight(.semibold))
            if status.setupState == .needsNewKit {
                NewKitBanner(planID: status.plan.id, context: context)
            }
            Picker("Tab", selection: $tab) {
                ForEach(PlanTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tab == .history {
                HistoryList(planID: status.plan.id)
            } else {
                ScrollView {
                    tabContent
                        .disabled(model.saving)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                }
            }
            Divider()
            SaveBar(model: model, planName: status.plan.name, planID: status.plan.id, context: context, deleted: deleted)
        }
        .padding(16)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .what: PlanWhatTab(model: model, identity: context.supervisor.identity)
        case .schedule: PlanScheduleTab(model: model)
        case .storage: PlanStorageTab(model: model) { context.showRecoveryKit(status.plan.id) }
        case .keep: PlanKeepTab(model: model)
        case .alerts: PlanAlertsTab(model: model)
        case .history: EmptyView()
        }
    }
}

/// "New recovery kit needed" (the menu's banner, UI design §6.2): backups wait until the new kit is confirmed.
private struct NewKitBanner: View {
    let planID: UUID
    let context: SettingsContext

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New recovery kit needed").font(.headline)
                    Text("Save the new kit so backups can carry on.").foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button(BannerAction.saveRecoveryKit(planID).buttonTitle) { context.showRecoveryKit(planID) }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The edits' state and the buttons: Delete Plan… on the left; the pause warning, the first problem or the save's
/// sentence, Revert and Save (⌘S) on the right. Save isn't the default button: Return belongs to the fields.
private struct SaveBar: View {
    @Bindable var model: PlanEditModel
    let planName: String
    let planID: UUID
    let context: SettingsContext
    let deleted: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            DeletePlanButton(planID: planID, planName: planName, context: context, deleted: deleted)
                .disabled(model.saving)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if model.edit.pausesBackups {
                    Label(PlanEdit.pauseWarning, systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
                if let error = model.saveError {
                    Text(error).foregroundStyle(.red)
                } else if model.edit.isDirty, let problem = model.edit.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            if model.saving { ProgressView().controlSize(.small) }
            Button("Revert") { model.revert() }
                .disabled(!model.edit.isDirty || model.saving)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.edit.isDirty || model.edit.problem != nil || model.saving)
        }
    }
}

/// Delete Plan… with the developer window's confirmation (the repository and its snapshots aren't touched). The
/// agent removes the plan's settings, keychain items, history and run logs.
private struct DeletePlanButton: View {
    let planID: UUID
    let planName: String
    let context: SettingsContext
    let deleted: () -> Void
    @State private var confirming = false
    @State private var deleting = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 6) {
            Button("Delete Plan…", role: .destructive) { confirming = true }
                .disabled(deleting)
            if deleting { ProgressView().controlSize(.small) }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Delete the plan \"\(planName)\"?", isPresented: $confirming) {
            Button("Delete Plan", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings, saved passwords and keys, and history are removed. The repository and its snapshots aren't touched.")
        }
    }

    private func delete() async {
        deleting = true
        problem = nil
        defer { deleting = false }
        switch await context.supervisor.connection.deletePlan(planID) {
        case .success: deleted()
        case .failure(let error): problem = FormValidation.sentence(error.description)
        }
    }
}

/// An unfinished plan: setup is still making it, so it is finished there (or deleted here).
private struct UnfinishedPlanView: View {
    let plan: Plan
    let context: SettingsContext
    let deleted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.name).font(.title3.weight(.semibold))
            Label("Setup not finished", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Finish setting it up to start backing up.")
            HStack {
                DeletePlanButton(planID: plan.id, planName: plan.name, context: context, deleted: deleted)
                Spacer()
                Button(BannerAction.finishSetup(plan.id).buttonTitle) { context.finishSetup() }
            }
            Spacer()
        }
        .padding(16)
    }
}

/// The plan editor Settings has open, owned by the window (`WindowRouter`) so it outlives a switch to another
/// section, and closed with the window so the typed secrets go at once.
@MainActor
@Observable
final class PlanEditorSlot {
    private(set) var editor: PlanEditModel?

    /// Closes the editor that was open (its secrets go) and keeps `editor`.
    func replace(with editor: PlanEditModel?) {
        self.editor?.close()
        self.editor = editor
    }

    func close() { replace(with: nil) }
}
