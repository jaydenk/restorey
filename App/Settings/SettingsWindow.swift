import AppKit
import Observation
import RestoreyCore
import SwiftUI

/// What Settings works with, from the shell: the installed copy's supervisor and login item, and the other windows
/// it opens. `WindowRouter` makes it; a copy outside /Applications has no Settings.
@MainActor
struct SettingsContext {
    let supervisor: AgentSupervisor
    let loginItem: LoginItem
    /// Setup where it was left (a plan's "Finish Setup…", like the menu's).
    let finishSetup: () -> Void
    /// Setup at this progress ("Add Plan…" once decided, or an unfinished plan's setup to finish first).
    let openSetup: (SetupProgress) -> Void
    /// What "Add Plan…" opens (`SetupFlow.addingPlan`); nil when the setup window was already open and has come
    /// forward instead.
    let addPlan: () -> AddPlanStart?
    let showRecoveryKit: (UUID) -> Void
    /// The Overview tab's "Restore Files…", as the menu's.
    let showRestoreFiles: (UUID) -> Void
    /// A plan was deleted: setup progress that names it is forgotten (live finding 2).
    let planDeleted: (UUID) -> Void
}

/// The Settings window's content (UI design §6, mockup `v0.1-settings.html`): the section the toolbar picks.
/// General, Plans, Network and History.
struct SettingsWindow: View {
    /// The narrowest every section fits in: General and History need about 760, Plans its tab row (`PlansPane`),
    /// measured now. `WindowRouter` takes it once per window made (Task 14c R2), so a text-size change applies from the next one.
    @MainActor static func measuredMinimumWidth() -> CGFloat {
        max(760, PlansPane.minimumWidth(tabRowWidth: PlanTabs<EmptyView>.naturalWidth()).rounded(.up))
    }

    let context: SettingsContext
    /// `measuredMinimumWidth()` when the window was made.
    let minimumWidth: CGFloat
    @Bindable var state: ShellState
    let editorSlot: PlanEditorSlot
    /// The Network section's unsaved edits, held by the router while the window is open.
    let networkSlot: NetworkEditorSlot

    var body: some View {
        Group {
            switch state.settingsSection {
            case .general:
                GeneralPane(context: context, state: state)
            case .plans:
                PlansPane(context: context, state: state, slot: editorSlot)
            case .network:
                NetworkPane(supervisor: context.supervisor, slot: networkSlot)
            case .history:
                HistoryPane(filterRequest: state.historyFilter)
            }
        }
        // Wide enough for every section, Plans' row of tabs the widest (measured, not guessed: a fixed 760 let the old
        // segmented row overflow, and the hosting view centred the overflow, clipping both edges; Task 14c R1).
        .frame(
            minWidth: minimumWidth, idealWidth: minimumWidth + 20, minHeight: 520, idealHeight: 560)
        .environment(context.supervisor)
        // Here rather than in Plans: a route from the menu can ask for another plan while any section shows.
        .alert(
            "Discard your changes to “\(editorSlot.editor?.saved.name ?? "")”?",
            isPresented: Binding(
                get: { state.planSelection.pending != nil }, set: { if !$0 { state.cancelPlanSwitch() } })
        ) {
            Button("Discard Changes", role: .destructive) {
                state.settingsSection = .plans
                state.confirmPlanSwitch()
            }
            Button("Keep Editing", role: .cancel) {
                state.settingsSection = .plans
                state.cancelPlanSwitch()
            }
        } message: {
            Text("They haven’t been saved.")
        }
    }
}

/// The window's toolbar of sections, as macOS Settings windows have it (`NSWindow.ToolbarStyle.preference`):
/// AppKit's, so the selected section shows the way the system draws it. It follows `ShellState`, which the
/// menu's routes also set (`WindowRouter.showSettings`), and writes the user's choice back to it.
@MainActor
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private let state: ShellState
    private let toolbar = NSToolbar(identifier: "RestoreySettings")
    private weak var window: NSWindow?

    init(state: ShellState) {
        self.state = state
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        follow()
    }

    private static func identifier(_ section: SettingsSection) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(section.rawValue)
    }

    private static func symbol(_ section: SettingsSection) -> String {
        switch section {
        case .general: "gearshape"
        case .plans: "list.bullet.rectangle"
        case .network: "network"
        case .history: "clock.arrow.circlepath"
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(Self.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(Self.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(Self.identifier)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let section = SettingsSection(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.title
        item.image = NSImage(systemSymbolName: Self.symbol(section), accessibilityDescription: section.title)
        item.target = self
        item.action = #selector(choose(_:))
        return item
    }

    @objc private func choose(_ item: NSToolbarItem) {
        guard let section = SettingsSection(rawValue: item.itemIdentifier.rawValue) else { return }
        // The user's own choice: a filter a route asked for no longer applies.
        state.historyFilter = nil
        state.settingsSection = section
    }

    /// Shows the state's section, and again each time it changes.
    private func follow() {
        let section = withObservationTracking {
            state.settingsSection
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        toolbar.selectedItemIdentifier = Self.identifier(section)
        window?.title = section.title
    }
}
