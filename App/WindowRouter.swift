import AppKit
import Observation
import RestoreyCore
import SwiftUI

/// What the shell's windows show that the shell, not the window, decides: the Settings section and plan asked
/// for, and whether the status item is hidden (the General section's note, UI design §8). Settings reads it and
/// writes the section and plan the user picks; `WindowRouter` and `AppDelegate` write it.
@MainActor
@Observable
final class ShellState {
    var settingsSection: SettingsSection = SettingsRoute.initial.section
    /// The plan Plans shows. Every change goes through `requestPlan`, so unsaved edits are never dropped unasked.
    private(set) var planSelection = PlanSelection<PlanTab>(selected: SettingsRoute.initial.planID)
    var settingsPlanID: UUID? { planSelection.selected }
    /// The plan the History section's list was last asked to show (the menu's "Show Details…"); a new request each
    /// time, so asking again for the same plan resets a filter the user changed. Cleared when the user picks a
    /// section and when Settings closes, so History opened later starts with every plan.
    var historyFilter: HistoryFilterRequest?
    /// The plan's tab shown in Plans; kept as the user switches plans.
    var settingsPlanTab: PlanTab = .what
    /// The status item's `isVisible` is false: the user hid it (System Settings → Menu Bar, or dragged it out).
    /// A status item squeezed out of a full menu bar still reads visible (`NSStatusItem.isVisible`).
    var statusItemHidden = false

    /// The one way to change the plan Plans shows: from the sidebar, the menu's routes and a reopen. `editing` is
    /// the plan with unsaved edits, if any (`PlanEditorSlot.unsavedPlanID`); a request for another then waits for
    /// the discard question (`PlanSelection`).
    /// A tab named with the plan (the menu's "Add…" opens Alerts) shows once the switch happens, now or after
    /// "Discard Changes".
    func requestPlan(_ planID: UUID?, tab: PlanTab? = nil, editing: UUID?) {
        if let tab = planSelection.request(planID, tab: tab, editing: editing) { settingsPlanTab = tab }
    }

    func confirmPlanSwitch() {
        if let tab = planSelection.confirm() { settingsPlanTab = tab }
    }
    func cancelPlanSwitch() { planSelection.cancel() }
    /// The plan shown was deleted.
    func forgetPlan() { planSelection.forget() }
}

/// A request for the History list's plan filter. Each is new (`id`), so a repeat of the same plan still applies.
struct HistoryFilterRequest: Equatable {
    let id = UUID()
    let planID: UUID?
}

/// Opens the app's windows: one per kind (`AppWindowKind`), brought to the front if it is already open, with
/// the app activated, since a menu bar app is usually not the active one when asked. The windows are never
/// state-restored, so a menu bar app doesn't reopen Settings by itself at every launch. Closing a window
/// releases it and its content, so a recovery kit's secrets go with it (and Settings' typed keys with its).
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    let state = ShellState()
    private let slots = WindowSlots<AppWindowKind, NSWindow>()
    /// The plan a recovery kit or Restore Files window shows.
    private var shownPlan: [AppWindowKind: UUID] = [:]
    /// Makes the setup window's model when it opens (`AppDelegate` supplies it: refused or installed), at the
    /// progress given, or where the saved progress says when nil.
    var makeSetupModel: ((SetupProgress?) -> SetupModel)?
    /// The installed copy's saved setup progress, for "+ Add plan…" (`AppDelegate` sets it).
    var setupStore: SetupProgressStore?
    /// The installed copy's open-at-login switch (`AppDelegate` sets it, P2-16): Settings → General. Like the
    /// supervisor, a copy outside /Applications has none, and no Settings.
    var loginItem: LoginItem?
    /// The Settings window's toolbar of sections, and the plan editor it holds, while the window is open.
    private var settingsToolbar: SettingsToolbar?
    private var planEditorSlot: PlanEditorSlot?
    /// The open setup window's model, told when the window closes so its secrets go at once.
    private var setupModel: SetupModel?
    /// The installed copy's supervisor (`AppDelegate` sets it): the recovery kit and Restore Files windows ask the
    /// agent through it. A refused copy has none, and opens neither.
    var supervisor: AgentSupervisor?
    /// The open recovery kit and Restore Files windows' models, told when their window closes or shows another plan,
    /// so the secrets they hold go at once.
    private var recoveryKitModel: RecoveryKitWindowModel?
    private var restoreFilesModel: RestoreFilesModel?

    /// Shows setup, at `progress` when the window isn't already open (an open one comes forward as it is).
    func showSetup(progress: SetupProgress? = nil) {
        guard let makeSetupModel else { return }
        show(.setup) { [weak self] in
            let model = makeSetupModel(progress)
            model.closeWindow = { [weak self] in self?.slots.openWindow(for: .setup)?.performClose(nil) }
            self?.setupModel = model
            let controller = NSHostingController(rootView: SetupWindow(model: model))
            // Each step is a different height: the window follows the content's ideal size as the step changes,
            // rather than keeping the first step's height and clipping the buttons of a taller one.
            controller.sizingOptions = [.preferredContentSize, .minSize]
            return controller
        }
    }

    /// Shows Settings. With neither argument, an open window comes forward as it is and a new one starts at
    /// Plans; a section or plan passed switches to it (`settingsRoute`), and a tab to that plan's tab.
    func showSettings(section: SettingsSection? = nil, planID: UUID? = nil, tab: PlanTab? = nil) {
        let open = slots.openWindow(for: .settings).map { _ in
            SettingsRoute(section: state.settingsSection, planID: state.settingsPlanID)
        }
        let route = settingsRoute(open: open, section: section, planID: planID)
        state.settingsSection = route.section
        if route.section == .history {
            // A plan asked for in History is the list's filter, not the plan Plans shows.
            if section != nil || planID != nil { state.historyFilter = HistoryFilterRequest(planID: route.planID) }
        } else {
            state.requestPlan(route.planID, tab: tab, editing: planEditorSlot?.unsavedPlanID)
        }
        guard let supervisor, let loginItem else { return }
        let context = SettingsContext(
            supervisor: supervisor, loginItem: loginItem,
            finishSetup: { [weak self] in self?.showSetup() },
            openSetup: { [weak self] in self?.showSetup(progress: $0) },
            addPlan: { [weak self] in self?.addPlan() },
            showRecoveryKit: { [weak self] in self?.showRecoveryKit(planID: $0) },
            planDeleted: { [weak self] in self?.setupStore?.forget(planID: $0) })
        show(.settings, configure: { [weak self, state] window in
            window.styleMask.insert(.resizable)
            let toolbar = SettingsToolbar(state: state)
            toolbar.attach(to: window)
            self?.settingsToolbar = toolbar
        }) { [weak self, state] in
            let slot = PlanEditorSlot()
            self?.planEditorSlot = slot
            let controller = NSHostingController(
                rootView: SettingsWindow(context: context, state: state, editorSlot: slot))
            // The window may be made larger than the content's minimum, never smaller.
            controller.sizingOptions = [.minSize]
            return controller
        }
    }

    /// "+ Add plan…" (`SetupFlow.addingPlan`): opens setup itself unless there is an unfinished plan's setup to
    /// finish first, which Settings asks about. An open setup window just comes forward (nil).
    private func addPlan() -> AddPlanStart? {
        if slots.openWindow(for: .setup) != nil {
            showSetup()
            return nil
        }
        guard let plans = supervisor?.lastKnownStatus?.plans else { return nil }
        return SetupFlow.addingPlan(saved: setupStore?.load(), plans: plans, installed: true)
    }

    /// "Save Recovery Kit…" (a plan needing a new kit) and Settings' "Show recovery kit…".
    func showRecoveryKit(planID: UUID) {
        guard let supervisor else { return }
        show(.recoveryKit, planID: planID) { [weak self] in
            self?.recoveryKitModel?.close()
            let model = RecoveryKitWindowModel(planID: planID, supervisor: supervisor) { [weak self] in self?.showSetup() }
            self?.recoveryKitModel = model
            return Self.sizedToContent(RecoveryKitWindow(model: model))
        }
    }

    /// The plan picked in the menu; the window's own picker can switch to another.
    func showRestoreFiles(planID: UUID) {
        guard let supervisor else { return }
        show(.restoreFiles, planID: planID) { [weak self] in
            self?.restoreFilesModel?.close()
            let model = RestoreFilesModel(planID: planID, supervisor: supervisor)
            self?.restoreFilesModel = model
            return Self.sizedToContent(RestoreFilesView(model: model))
        }
    }

    /// A window that follows its content's ideal size, as the kit loads or the plan changes.
    private static func sizedToContent(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize, .minSize]
        return controller
    }

    func show(_ opening: ShellOpening) {
        switch opening {
        case .setup: showSetup()
        case .settings(let section): showSettings(section: section)
        case .damagedNotice: break // AppDelegate shows it: the router has no window for it
        }
    }

    /// Shows the window of `kind`, making it with `content` if none is open. A plan's window asked for another
    /// plan gets fresh content, so nothing of the first plan stays in it.
    private func show(
        _ kind: AppWindowKind, planID: UUID? = nil, configure: (NSWindow) -> Void = { _ in },
        content: () -> NSViewController
    ) {
        let (window, isNew) = slots.window(for: kind) { makeWindow(kind, content: content()) }
        if isNew { configure(window) }
        if let planID {
            if !isNew, shownPlan[kind] != planID { window.contentViewController = content() }
            shownPlan[kind] = planID
        }
        if isNew { window.center() }
        WindowActivation.bringForward(window, as: .window(kind))
    }

    private func makeWindow(_ kind: AppWindowKind, content: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: content)
        window.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        window.title = kind.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// Ruling R1: closing Settings with unsaved plan edits asks Save, Don't Save or Cancel, as switching plans asks.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.identifier?.rawValue == AppWindowKind.settings.rawValue, let editor = planEditorSlot?.editor,
            editor.edit.isDirty
        else { return true }
        askToSave(editor, in: sender) { proceed in if proceed { sender.close() } }
        return false
    }

    enum QuitQuestion {
        /// Nothing unsaved: quit now.
        case none
        /// Asked; `reply` will say whether the quit goes on.
        case asked
        /// Settings already has a question up (closing it, or discarding changes): the quit is cancelled, and the
        /// window brought forward so that question is answered first. Chaining onto it would mean guessing what each
        /// answer means for the quit; cancelling leaves nothing waiting on a sheet that may never answer it.
        case busy
    }

    /// Fix round 2: quitting with unsaved plan edits asks the same question, over the Settings window. `reply` gets
    /// whether the quit may go on: after a save that worked or "Don't Save", not after Cancel or a refused save.
    func askBeforeQuitting(_ reply: @escaping @MainActor (Bool) -> Void) -> QuitQuestion {
        guard let window = slots.openWindow(for: .settings), let editor = planEditorSlot?.editor, editor.edit.isDirty
        else { return .none }
        WindowActivation.bringForward(window, as: .window(.settings))
        if window.attachedSheet != nil { return .busy }
        askToSave(editor, in: window, then: reply)
        return .asked
    }

    /// Save, Don't Save or Cancel for `editor`'s unsaved edits, as a sheet on `window`. `then` gets true once the
    /// edits are saved or discarded, false for Cancel or a save that was refused (shown in Plans, where it says why).
    private func askToSave(_ editor: PlanEditModel, in window: NSWindow, then: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(editor.saved.name)”?"
        let lost = "If you don't save, your changes are lost."
        alert.informativeText = editor.edit.pausesBackups ? "\(PlanEdit.pauseWarning) \(lost)" : lost
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    await editor.save()
                    if editor.edit.isDirty {
                        self?.state.settingsSection = .plans
                        then(false)
                    } else {
                        then(true)
                    }
                }
            case .alertSecondButtonReturn:
                editor.revert()
                then(true)
            default:
                then(false)
            }
        }
    }

    /// Setup's permissions poll runs only while its window can be seen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.identifier?.rawValue == AppWindowKind.setup.rawValue
        else { return }
        setupModel?.windowVisible = window.occlusionState.contains(.visible)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let raw = window.identifier?.rawValue, let kind = AppWindowKind(rawValue: raw)
        else { return }
        slots.closed(window, for: kind)
        shownPlan[kind] = nil
        switch kind {
        case .setup:
            setupModel?.close()
            setupModel = nil
        case .recoveryKit:
            recoveryKitModel?.close()
            recoveryKitModel = nil
        case .restoreFiles:
            restoreFilesModel?.close()
            restoreFilesModel = nil
        case .settings:
            state.historyFilter = nil
            planEditorSlot?.close()
            planEditorSlot = nil
            settingsToolbar = nil
        }
        // The content (and anything secret it holds) goes now, not when AppKit lets go of the window.
        window.contentViewController = nil
        WindowActivation.windowClosed(.window(kind))
    }
}
