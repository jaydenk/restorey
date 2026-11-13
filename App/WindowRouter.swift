import AppKit
import Observation
import RestoreyCore
import SwiftUI

/// What the shell's windows show that the shell, not the window, decides: the Settings section and plan asked
/// for, and whether the status item is hidden (the General section's note, UI design §8). Settings (Task 14)
/// reads it; `WindowRouter` and `AppDelegate` write it.
@MainActor
@Observable
final class ShellState {
    var settingsSection: SettingsSection = SettingsRoute.initial.section
    var settingsPlanID: UUID? = SettingsRoute.initial.planID
    /// The status item's `isVisible` is false: the user hid it (System Settings → Menu Bar, or dragged it out).
    /// A status item squeezed out of a full menu bar still reads visible (`NSStatusItem.isVisible`).
    var statusItemHidden = false
}

/// Opens the app's windows: one per kind (`AppWindowKind`), brought to the front if it is already open, with
/// the app activated, since a menu bar app is usually not the active one when asked. The windows are never
/// state-restored, so a menu bar app doesn't reopen Settings by itself at every launch. Closing a window
/// releases it and its content, so a recovery kit's secrets go with it.
///
/// Until Settings (Task 14), the recovery kit (Task 13) and Restore Files exist, each of those windows holds a
/// placeholder.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    let state = ShellState()
    private let slots = WindowSlots<AppWindowKind, NSWindow>()
    /// The plan a recovery kit or Restore Files window shows.
    private var shownPlan: [AppWindowKind: UUID] = [:]
    /// Makes the setup window's model when it opens (`AppDelegate` supplies it: refused or installed).
    var makeSetupModel: (() -> SetupModel)?
    /// The open setup window's model, told when the window closes so its secrets go at once.
    private var setupModel: SetupModel?

    func showSetup() {
        guard let makeSetupModel else { return }
        show(.setup) { [weak self] in
            let model = makeSetupModel()
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
    /// Plans; a section or plan passed switches to it (`settingsRoute`).
    func showSettings(section: SettingsSection? = nil, planID: UUID? = nil) {
        let open = slots.openWindow(for: .settings).map { _ in
            SettingsRoute(section: state.settingsSection, planID: state.settingsPlanID)
        }
        let route = settingsRoute(open: open, section: section, planID: planID)
        state.settingsSection = route.section
        state.settingsPlanID = route.planID
        show(.settings) { [state] in NSHostingController(rootView: SettingsPlaceholderView(state: state)) }
    }

    func showRecoveryKit(planID: UUID) {
        show(.recoveryKit, planID: planID) { NSHostingController(rootView: PlaceholderView(kind: .recoveryKit, planID: planID)) }
    }

    func showRestoreFiles(planID: UUID) {
        show(.restoreFiles, planID: planID) { NSHostingController(rootView: PlaceholderView(kind: .restoreFiles, planID: planID)) }
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
    private func show(_ kind: AppWindowKind, planID: UUID? = nil, content: () -> NSViewController) {
        let (window, isNew) = slots.window(for: kind) { makeWindow(kind, content: content()) }
        if let planID {
            if !isNew, shownPlan[kind] != planID { window.contentViewController = content() }
            shownPlan[kind] = planID
        }
        if isNew { window.center() }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
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
        if kind == .setup {
            setupModel?.close()
            setupModel = nil
        }
        // The content (and anything secret it holds) goes now, not when AppKit lets go of the window.
        window.contentViewController = nil
    }
}

private struct PlaceholderView: View {
    let kind: AppWindowKind
    var planID: UUID?

    var body: some View {
        VStack(spacing: 8) {
            Text(kind.title).font(.title2)
            if let planID { Text("Plan \(planID.uuidString)").font(.caption).foregroundStyle(.secondary) }
            Text("This window isn't built yet.").foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 480, height: 280)
    }
}

/// Stands in for Task 14's Settings window: the four sections, and the General section's hidden-icon note.
private struct SettingsPlaceholderView: View {
    @Bindable var state: ShellState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Section", selection: $state.settingsSection) {
                ForEach(SettingsSection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if state.settingsSection == .general, state.statusItemHidden {
                Label(statusItemHiddenNote, systemImage: "menubar.rectangle")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("The \(state.settingsSection.title) section isn't built yet.").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 320)
    }
}
