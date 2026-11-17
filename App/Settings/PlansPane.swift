import AppKit
import RestoreyCore
import SwiftUI

/// Settings → Plans (UI design §6.2, mockup `v0.1-settings.html`): the plans in a bordered list with + and − under it,
/// as a settings pane with a list of things has them (Mail's Accounts, Users & Groups; Task 17c, P9), and the selected
/// plan's tabs. An unfinished plan offers "Finish Setup…" instead of tabs, since setup is still editing it. The plan's
/// edits live in one `PlanEditModel`, made afresh for each plan shown, so switching plans (after "Discard Changes" when
/// something is unsaved) or closing the window drops what was typed. It is held by the window (`PlanEditorSlot`), not
/// this pane, so going to General and back keeps unsaved edits.
struct PlansPane: View {
    let context: SettingsContext
    @Bindable var state: ShellState
    let slot: PlanEditorSlot
    @State private var finishFirst: FinishFirst?
    /// The plan − (or Delete, or the row's menu) asked to delete, while its confirmation is up.
    @State private var deleting: DeleteRequest?
    @State private var deletionInProgress = false
    @State private var deletionProblem: String?

    private struct FinishFirst {
        let progress: SetupProgress
        let name: String
    }

    private struct DeleteRequest {
        let planID: UUID
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

    static let listWidth: CGFloat = 200
    /// The space around the list and the plan's page.
    static let pagePadding: CGFloat = 16

    /// The narrowest the pane can be with every tab showing in full: the list, the gap after it, and the tab row
    /// (`tabRowWidth`, measured) inside the page's padding. The Settings window's minimum width comes from it (Task 14c R1).
    static func minimumWidth(tabRowWidth: CGFloat) -> CGFloat {
        listWidth + 3 * pagePadding + tabRowWidth
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.pagePadding) {
            planList.frame(width: Self.listWidth)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Self.pagePadding)
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
        // The developer window's words (the repository and its snapshots aren't touched).
        .confirmationDialog(
            "Delete the plan “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { request in
            Button("Delete Plan", role: .destructive) { Task { await delete(request) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its settings, saved passwords and keys, and history are removed. The repository and its snapshots aren’t touched.")
        }
    }

    // MARK: The list of plans

    private var listAvailable: Bool { status != nil && status?.configError == nil }

    private var planList: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { selectedID }, set: choose)) {
                    ForEach(plans, id: \.plan.id) { plan in
                        PlanRow(plan: plan)
                            .tag(UUID?.some(plan.plan.id))
                            .contextMenu {
                                Button("Delete Plan…") { askToDelete(plan.plan) }
                                    .disabled(deletionInProgress)
                            }
                    }
                }
                .listStyle(.bordered)
                .onDeleteCommand { if let selected { askToDelete(selected.plan) } }
                .accessibilityLabel("Plans")
                ListAddRemoveBar(
                    addName: "Add Plan…", removeName: "Delete Plan…", add: addPlan,
                    remove: { if let selected { askToDelete(selected.plan) } },
                    canAdd: listAvailable, canRemove: selected != nil && !deletionInProgress && slot.editor?.saving != true)
            }
            if deletionInProgress {
                ProgressView().controlSize(.small)
            }
            if let deletionProblem {
                SeverityText(deletionProblem)
            }
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

    private func askToDelete(_ plan: Plan) {
        // Not while that plan's edits are being saved.
        guard !deletionInProgress, !(slot.editor?.planID == plan.id && slot.editor?.saving == true) else { return }
        deletionProblem = nil
        deleting = DeleteRequest(planID: plan.id, name: plan.name)
    }

    /// The agent removes the plan's settings, keychain items, history and run logs.
    private func delete(_ request: DeleteRequest) async {
        deletionInProgress = true
        defer { deletionInProgress = false }
        switch await context.supervisor.connection.deletePlan(request.planID) {
        case .success:
            context.planDeleted(request.planID)
            if request.planID == selectedID { state.forgetPlan() }
        case .failure(let error): deletionProblem = FormValidation.sentence(error.description)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let configError = status?.configError {
            // The menu's wording (`MenuPresentation`).
            SeverityText("Restorey can’t read its settings: \(configError)")
        } else if status == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for Restorey’s background process…").foregroundStyle(.secondary)
            }
        } else if let selected {
            if selected.setupState == .unfinished {
                UnfinishedPlanView(plan: selected.plan, context: context)
            } else if let editor = slot.editor, editor.planID == selected.plan.id {
                PlanDetail(status: selected, model: editor, context: context, tab: $state.settingsPlanTab)
                    .id(selected.plan.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No backup plans yet").font(.headline)
                Text("Add one to start backing up this Mac.").foregroundStyle(.secondary)
            }
        }
    }
}

/// A plan in the list: where it backs up to as a symbol (a drive or folder on this Mac, or another machine), its name,
/// and the note under it.
private struct PlanRow: View {
    let plan: PlanStatus

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.plan.name).lineLimit(1)
                if let note = PlanNote.sidebar(plan) {
                    PlanListNote(note: note)
                }
            }
        } icon: {
            Image(systemName: plan.plan.repository.needsNetwork ? "cloud" : "externaldrive")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }
}

/// The note under a plan's name in the list: a tinted symbol, then the words in the secondary label colour. On the
/// selected row, whose background is the accent colour, the symbol is drawn in the secondary label colour too, so
/// it stays legible there.
private struct PlanListNote: View {
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

/// A plan's tabs (UI design §6.2; Task 17c, P10): six, the most the HIG's tab views allow, named for what each holds.
/// Which one shows is `ShellState.settingsPlanTab`, so the menu's "No off-Mac monitoring — Add…" can open Schedule,
/// whose Alerts section holds the check-in URL.
enum PlanTab: String, CaseIterable, Identifiable {
    /// First, and where a plan opens (Task 14c): the menu's line for the plan, with its actions.
    case overview, folders, schedule, storage, retention, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .folders: "Folders"
        case .schedule: "Schedule"
        case .storage: "Storage"
        case .retention: "Retention"
        case .history: "History"
        }
    }

    /// The tabs with nothing to edit: their page has the save bar only while edits from elsewhere wait (a sheet's "Don’t
    /// Back Up" adds an exclusion from either).
    var isEditable: Bool { self != .overview && self != .history }
}

/// The tabs of a plan's page as the system draws a tab view (HIG Tab views: "Use a tab view in the main window area —
/// instead of a segmented control — for view switching"): AppKit's `NSTabView`, with the shown tab's SwiftUI page in a
/// hosting view. SwiftUI's own `TabView` (`.grouped`) was tried first, and its tab row came out at zero size, the labels
/// cut to "F…", "S…" (an off-screen render, Task 17c), for the reason given in `makeNSView`, which SwiftUI's wrapper
/// gives no way to fix. Only the shown tab has its page; the others are made when chosen. The pages get the window's
/// `AgentSupervisor` again, since a hosting view starts a new environment.
struct PlanTabs<Content: View>: NSViewRepresentable {
    @Binding var tab: PlanTab
    let supervisor: AgentSupervisor?
    @ViewBuilder let content: (PlanTab) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(tab: $tab) }

    func makeNSView(context: Context) -> NSView {
        let tabs = NSTabView()
        for tab in PlanTab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = NSView()
            tabs.addTabViewItem(item)
        }
        tabs.selectTabViewItem(withIdentifier: tab.rawValue)
        tabs.delegate = context.coordinator
        // In a plain container that SwiftUI sizes, following it by its autoresizing mask as a tab view in an AppKit
        // window does.
        let container = NSView(frame: tabs.frame)
        tabs.autoresizingMask = [.width, .height]
        container.addSubview(tabs)
        context.coordinator.tabs = tabs
        // The tab row is itself hosted SwiftUI (`NSTabViewSegmentedControl`), and it can't measure itself while the
        // window's SwiftUI is mid-update, which is when this runs: it measured 0 × 0, and the tab view sizes its row
        // only when its tabs change, not when it is resized, so the row stayed that size (measured in an off-screen
        // render, Task 17c, where a tab view made outside an update sized its row to the labels at once). The labels
        // are given again once this update has finished, which makes the tab view measure the row afresh.
        DispatchQueue.main.async { [weak tabs] in
            for item in tabs?.tabViewItems ?? [] {
                let label = item.label
                item.label = ""
                item.label = label
            }
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let tabs = context.coordinator.tabs else { return }
        context.coordinator.tab = $tab
        if tabs.selectedTabViewItem?.identifier as? String != tab.rawValue {
            context.coordinator.updating = true
            tabs.selectTabViewItem(withIdentifier: tab.rawValue)
            context.coordinator.updating = false
        }
        guard let item = tabs.selectedTabViewItem else { return }
        let page = AnyView(content(tab).environment(supervisor))
        if let host = item.view as? NSHostingView<AnyView> {
            host.rootView = page
        } else {
            item.view = NSHostingView(rootView: page)
        }
        // A tab not shown keeps no page, so nothing in it runs (its tasks, its timers) until it is chosen again.
        for other in tabs.tabViewItems where other !== item && other.view is NSHostingView<AnyView> {
            other.view = NSView()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTabViewDelegate {
        var tab: Binding<PlanTab>
        var updating = false
        weak var tabs: NSTabView?
        init(tab: Binding<PlanTab>) { self.tab = tab }

        func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
            guard !updating, let raw = item?.identifier as? String, let chosen = PlanTab(rawValue: raw) else { return }
            if tab.wrappedValue != chosen { tab.wrappedValue = chosen }
        }
    }

    /// The tab row's natural width with the system's fonts as they are now: what the tab view's own row needs for the
    /// six labels. Measured each time a Settings window is made (`WindowRouter.showSettings`), so a change to the text
    /// size applies from the next one; one off-screen tab view, so cheap.
    @MainActor static func naturalWidth() -> CGFloat {
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 2000, height: 100))
        for tab in PlanTab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            tabs.addTabViewItem(item)
        }
        tabs.layoutSubtreeIfNeeded()
        let row = tabs.subviews.compactMap { $0 as? NSSegmentedControl }.first
        // The row's own width, plus the tab view's inset from its frame on each side.
        return (row?.intrinsicContentSize.width ?? tabs.minimumSize.width) + 2 * 12
    }
}

/// A plan that finished setup: its name and any banner, its tabs, and the save bar.
private struct PlanDetail: View {
    let status: PlanStatus
    @Bindable var model: PlanEditModel
    let context: SettingsContext
    @Binding var tab: PlanTab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.plan.name).pageTitle()
            if let stop = PlanNote.stop(status) {
                StopBanner(note: stop)
            }
            if status.setupState == .needsNewKit {
                NewKitBanner(planID: status.plan.id, context: context)
            }
            PlanTabs(tab: $tab, supervisor: context.supervisor) { tab in
                page(tab)
            }
            if tab.isEditable || model.edit.isDirty {
                SaveBar(model: model)
            }
        }
    }

    @ViewBuilder private func page(_ tab: PlanTab) -> some View {
        switch tab {
        case .overview: PlanOverviewTab(planID: status.plan.id, context: context, model: model)
        case .folders:
            PlanFoldersTab(
                model: model, identity: context.supervisor.identity,
                fullDiskAccessMissing: context.supervisor.lastKnownStatus?.fdaMissing == true)
                .disabled(model.saving)
        case .schedule: PlanScheduleTab(model: model, status: status).disabled(model.saving)
        case .storage:
            PlanStorageTab(model: model) { context.showRecoveryKit(status.plan.id) }.disabled(model.saving)
        case .retention: PlanRetentionTab(model: model, connection: context.supervisor.connection).disabled(model.saving)
        case .history: HistoryList(planID: status.plan.id, editor: model).padding(12)
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
