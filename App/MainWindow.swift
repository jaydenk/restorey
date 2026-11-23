import AppKit
import RestoreyCore
import SwiftUI

/// The main window's content (visual polish §1; UI design §6.2 and §6.4): the section the toolbar picks, Plans or
/// History. It holds the plan editor (`PlanEditorSlot`, the router's while the window is open), so going to History
/// and back keeps unsaved plan edits, and closing the window asks about them (`WindowRouter.windowShouldClose`).
struct MainWindow: View {
    /// The narrowest both sections fit in: History needs about 760, Plans its tab row (`PlansPane`), measured now.
    /// `WindowRouter` takes it once per window made (Task 14c R2), so a text-size change applies from the next one.
    @MainActor static func measuredMinimumWidth() -> CGFloat {
        max(760, PlansPane.minimumWidth(tabRowWidth: PlanTabPicker.naturalWidth()).rounded(.up))
    }

    let context: SettingsContext
    /// `measuredMinimumWidth()` when the window was made.
    let minimumWidth: CGFloat
    @Bindable var state: ShellState
    let editorSlot: PlanEditorSlot

    var body: some View {
        Group {
            switch state.mainSection {
            case .plans:
                PlansPane(context: context, state: state, slot: editorSlot)
            case .history:
                HistoryPane(filterRequest: state.historyFilter)
            }
        }
        // Wide enough for both sections, Plans' row of tabs the wider (measured, not guessed: a fixed 760 let the old
        // segmented row overflow, and the hosting view centred the overflow, clipping both edges; Task 14c R1).
        .frame(minWidth: minimumWidth, idealWidth: minimumWidth + 20, minHeight: 520, idealHeight: 560)
        .environment(context.supervisor)
        // Here rather than in Plans: a route from the menu can ask for another plan while History shows.
        .alert(
            "Discard your changes to “\(editorSlot.editor?.saved.name ?? "")”?",
            isPresented: Binding(
                get: { state.planSelection.pending != nil }, set: { if !$0 { state.cancelPlanSwitch() } })
        ) {
            Button("Discard Changes", role: .destructive) {
                state.mainSection = .plans
                state.confirmPlanSwitch()
            }
            Button("Keep Editing", role: .cancel) {
                state.mainSection = .plans
                state.cancelPlanSwitch()
            }
        } message: {
            Text("They haven’t been saved.")
        }
    }
}

extension MainSection {
    /// The SF Symbol on the section's toolbar item.
    var symbolName: String {
        switch self {
        case .plans: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

extension SectionToolbar {
    /// The main window's sections, Plans then History.
    static func main(state: ShellState) -> SectionToolbar {
        SectionToolbar(
            identifier: "RestoreyMainToolbar",
            items: MainSection.allCases.map { Item(id: $0.rawValue, title: $0.title, symbolName: $0.symbolName) },
            selected: { state.mainSection.rawValue },
            choose: { id in
                guard let section = MainSection(rawValue: id) else { return }
                // The user's own choice: a filter a route asked for no longer applies.
                state.historyFilter = nil
                state.mainSection = section
            })
    }
}
