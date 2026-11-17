import AppKit
import RestoreyCore
import SwiftUI

/// Settings → Plans (UI design §6.2, mockup `v0.1-settings.html`): the plans in a sidebar with "Add Plan…", and
/// the selected plan's tabs. An unfinished plan offers "Finish Setup…" instead of tabs, since setup is still
/// editing it. The plan's edits live in one `PlanEditModel`, made afresh for each plan shown, so switching plans
/// (after "Discard Changes" when something is unsaved) or closing the window drops what was typed. It is held by
/// the window (`PlanEditorSlot`), not this pane, so going to General and back keeps unsaved edits.
struct PlansPane: View {
    let context: SettingsContext
    @Bindable var state: ShellState
    let slot: PlanEditorSlot
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

    static let sidebarWidth: CGFloat = 200
    /// The plan page's padding on each side.
    static let pagePadding: CGFloat = 16

    /// The narrowest the pane can be with every tab showing in full: the sidebar, its divider, and the tab row
    /// (`tabRowWidth`, measured) inside the page's padding. The Settings window's minimum width comes from it (Task 14c R1).
    static func minimumWidth(tabRowWidth: CGFloat) -> CGFloat {
        sidebarWidth + 1 + 2 * pagePadding + tabRowWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: Self.sidebarWidth)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: editorKey, initial: true) { openEditor() }
        .onChange(of: selected?.plan) { if let plan = selected?.plan { slot.editor?.rebase(on: plan) } }
        .alert(
            "Finish setting up “\(finishFirst?.name ?? "")” first",
            isPresented: Binding(get: { finishFirst != nil }, set: { if !$0 { finishFirst = nil } }),
            presenting: finishFirst
        ) { pending in
            Button("Finish Setup…") { context.openSetup(pending.progress) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Restorey sets up one plan at a time. Finish that plan’s setup, or delete it here, then add another.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedID }, set: choose)) {
                ForEach(plans, id: \.plan.id) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.plan.name).lineLimit(1)
                        if let note = PlanNote.sidebar(plan) {
                            SidebarNote(note: note)
                        }
                    }
                    .tag(UUID?.some(plan.plan.id))
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button("Add Plan…", action: addPlan)
                    .buttonStyle(.borderless)
                    .disabled(status == nil || status?.configError != nil)
                Spacer()
            }
            .padding(8)
        }
    }

    /// Through the one guard (`ShellState.requestPlan`): a switch away from unsaved edits asks first.
    private func choose(_ id: UUID?) {
        guard let id, id != selectedID else { return }
        state.requestPlan(
            id, landing: planRequestLandsOnFirstTab(.sidebarPick) ? .overview : nil, editing: slot.unsavedPlanID)
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
            SeverityText("Restorey can’t read its settings: \(configError)")
                .padding(16)
        } else if status == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for Restorey’s background process…").foregroundStyle(.secondary)
            }
            .padding(16)
        } else if let selected {
            if selected.setupState == .unfinished {
                UnfinishedPlanView(plan: selected.plan, context: context) { state.forgetPlan() }
            } else if let editor = slot.editor, editor.planID == selected.plan.id {
                PlanDetail(status: selected, model: editor, context: context, tab: $state.settingsPlanTab) {
                    state.forgetPlan()
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

/// The note under a plan's name in the sidebar: a tinted symbol, then the words in the secondary label colour. On the
/// selected row, whose background is the accent colour, the symbol is drawn in the secondary label colour too, so
/// it stays legible there.
private struct SidebarNote: View {
    let note: PlanNote
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let severity: Severity = note.level == .error ? .error : .warning
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: severity.symbolName)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(severity.tint))
                .accessibilityLabel(severity.accessibilityLabel)
            Text(note.title).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

/// A plan's tabs (UI design §6.2). Which one shows is `ShellState.settingsPlanTab`, so the menu's "No off-Mac
/// monitoring — Add…" can open Alerts.
enum PlanTab: String, CaseIterable, Identifiable {
    /// First, and where a plan opens (Task 14c): the menu's line for the plan, with its actions.
    case overview, what, schedule, storage, keep, alerts, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .what: "What"
        case .schedule: "Schedule"
        case .storage: "Storage"
        case .keep: "Keep"
        case .alerts: "Alerts"
        case .history: "History"
        }
    }
}

/// The row of a plan's tabs. A segmented control doesn't shrink below its segments, so it keeps its natural width
/// (`fixedSize`) and the window is made wide enough for it (`PlansPane.minimumWidth`) rather than letting it overflow:
/// overflowing content is centred by the hosting view and clipped at both edges (Task 14c R1).
struct PlanTabPicker: View {
    @Binding var tab: PlanTab

    var body: some View {
        Picker("Tab", selection: $tab) {
            ForEach(PlanTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// The row's natural width with the system's fonts as they are now. Measured each time a Settings window is made
    /// (`WindowRouter.showSettings`), so a change to the text size applies from the next window; one off-screen
    /// layout of a seven-segment control, so cheap.
    @MainActor static func naturalWidth() -> CGFloat {
        NSHostingView(rootView: PlanTabPicker(tab: .constant(.overview))).fittingSize.width
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
            Text(status.plan.name).pageTitle()
            if let stop = PlanNote.stop(status) {
                StopBanner(note: stop)
            }
            if status.setupState == .needsNewKit {
                NewKitBanner(planID: status.plan.id, context: context)
            }
            PlanTabPicker(tab: $tab)
            if tab == .history {
                HistoryList(planID: status.plan.id, editor: model)
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
        .padding(PlansPane.pagePadding)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .overview: PlanOverviewTab(planID: status.plan.id, context: context, model: model)
        case .what:
            PlanWhatTab(
                model: model, identity: context.supervisor.identity,
                fullDiskAccessMissing: context.supervisor.lastKnownStatus?.fdaMissing == true)
        case .schedule: PlanScheduleTab(model: model, status: status)
        case .storage: PlanStorageTab(model: model) { context.showRecoveryKit(status.plan.id) }
        case .keep: PlanKeepTab(model: model, connection: context.supervisor.connection)
        case .alerts: PlanAlertsTab(model: model)
        case .history: EmptyView()
        }
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

    /// The plan whose edits aren't saved, if any: what a request for another plan must ask about.
    var unsavedPlanID: UUID? { editor?.edit.isDirty == true ? editor?.planID : nil }
}
