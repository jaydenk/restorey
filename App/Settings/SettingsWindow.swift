import AppKit
import Observation
import RestoreyCore
import SwiftUI

/// What the main and Settings windows work with, from the shell: the installed copy's supervisor and login item, and
/// the other windows they open. `WindowRouter` makes it; a copy outside /Applications has neither window.
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

/// The Settings window's content (visual polish §1): the pane the toolbar picks, General, Notifications or Network,
/// at a fixed width with the height the pane needs, as System Settings-style preference windows have it.
struct SettingsWindow: View {
    /// The window's one width. Every pane's rows fit in it, the Network pane's limit window (a days menu and two
    /// times) the widest; longer text wraps.
    static let width: CGFloat = 560
    static let minimumHeight: CGFloat = 160

    let context: SettingsContext
    @Bindable var state: ShellState
    /// The Network pane's unsaved edits, held by the router while the window is open.
    let networkSlot: NetworkEditorSlot

    var body: some View {
        Group {
            switch state.settingsPane {
            case .general:
                GeneralPane(context: context, state: state)
            case .notifications:
                NotificationsPane(supervisor: context.supervisor)
            case .network:
                NetworkPane(supervisor: context.supervisor, slot: networkSlot)
            }
        }
        // The pane's own height, which the window takes (`sizingOptions = .preferredContentSize`): a grouped form
        // reports its rows' height when not stretched, so the window neither scrolls a short pane nor pads it. A pane
        // still waiting for its first status (a spinner) keeps a usable height rather than a sliver.
        .frame(minHeight: Self.minimumHeight)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(context.supervisor)
    }
}

extension SectionToolbar {
    /// The Settings window's panes, in `SettingsPane` order.
    static func settings(state: ShellState) -> SectionToolbar {
        SectionToolbar(
            identifier: "RestoreySettingsToolbar",
            items: SettingsPane.allCases.map { Item(id: $0.rawValue, title: $0.title, symbolName: $0.symbolName) },
            selected: { state.settingsPane.rawValue },
            choose: { id in if let pane = SettingsPane(rawValue: id) { state.settingsPane = pane } })
    }
}

/// A window's toolbar of sections or panes, as macOS Settings windows have it: AppKit's selectable toolbar items, so
/// the selected one shows the way the system draws it. It follows `selected` (which the menu's routes also change,
/// through `ShellState`), titles the window with the selected item's name, and passes the user's pick to `choose`.
/// The main window (Plans, History) and the Settings window (General, Notifications, Network) each have one.
@MainActor
final class SectionToolbar: NSObject, NSToolbarDelegate {
    struct Item {
        let id: String
        let title: String
        let symbolName: String
    }

    private let toolbar: NSToolbar
    private let items: [Item]
    private let selected: @MainActor () -> String
    private let choose: @MainActor (String) -> Void
    private weak var window: NSWindow?

    /// `selected` is read under observation tracking, so it should read observable state (`ShellState`).
    init(
        identifier: String, items: [Item], selected: @escaping @MainActor () -> String,
        choose: @escaping @MainActor (String) -> Void
    ) {
        toolbar = NSToolbar(identifier: identifier)
        self.items = items
        self.selected = selected
        self.choose = choose
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }

    func attach(to window: NSWindow, style: NSWindow.ToolbarStyle) {
        self.window = window
        window.toolbar = toolbar
        window.toolbarStyle = style
        follow()
    }

    private var identifiers: [NSToolbarItem.Identifier] { items.map { NSToolbarItem.Identifier($0.id) } }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let section = items.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.title
        item.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        item.target = self
        item.action = #selector(chose(_:))
        return item
    }

    @objc private func chose(_ item: NSToolbarItem) {
        choose(item.itemIdentifier.rawValue)
    }

    /// Shows the selected item, and again each time it changes; the window's title is its name (HIG Settings: "update
    /// the window's title to reflect the currently visible pane").
    private func follow() {
        let id = withObservationTracking {
            selected()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(id)
        if let title = items.first(where: { $0.id == id })?.title { window?.title = title }
    }
}
