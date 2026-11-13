import AppKit
import Observation
import RestoreyCore

/// The setup window's state (UI design §4): the saved progress, the plan being built and the current step's
/// secrets, all in `SetupDraft`, plus what the permissions screens show. The secrets go when the step changes
/// and when the window closes (`close`, called by `WindowRouter`); they are never logged or saved. The step
/// order and Continue rules are `SetupFlow`'s.
@MainActor
@Observable
final class SetupModel {
    enum Context {
        /// A copy outside /Applications: only the move screen, and nothing of the agent's.
        case refused(AppMover)
        case installed(AgentSupervisor, LoginItem)
    }

    /// How often the permissions step asks the agent about Full Disk Access while it is shown (P2-11).
    static let fullDiskAccessPollInterval: Duration = .seconds(2)

    private(set) var draft: SetupDraft
    var step: SetupStep { draft.step }
    var heading: String { draft.step.heading(addingPlan: draft.progress.addingPlan) }

    // Move to Applications
    private(set) var moveDecision: AppMoveDecision?
    private(set) var moving = false
    private(set) var moveError: String?

    // Permissions
    private(set) var fullDiskAccessGranted = false
    private(set) var fullDiskAccessError: String?
    private(set) var requestingNotifications = false
    @ObservationIgnored private var notificationsAnswer: Bool?
    /// P2-16: on by default; applied when the step is left with Continue.
    var openAtLogin: Bool
    private(set) var loginItemError: String?

    @ObservationIgnored private let context: Context
    @ObservationIgnored private let store: SetupProgressStore

    init(context: Context, progress: SetupProgress, store: SetupProgressStore) {
        self.context = context
        self.store = store
        draft = SetupDraft(progress: progress)
        switch context {
        case .refused:
            openAtLogin = true
        case .installed(let supervisor, let loginItem):
            fullDiskAccessGranted = supervisor.lastKnownStatus?.fdaMissing == false
            // Off only when the user has switched Restorey off in Login Items.
            openAtLogin = loginItem.status != .requiresApproval
        }
        // A refused copy saves nothing: the installed copy's place in setup must survive a stray copy being run.
        if case .installed = context { store.save(progress) }
    }

    var installed: Bool {
        if case .installed = context { return true }
        return false
    }

    /// The window is closing: the step's secrets go now. The progress stays saved for the next opening.
    func close() {
        draft.close()
    }

    private var facts: SetupFacts {
        SetupFacts(
            installed: installed, fdaGranted: fullDiskAccessGranted, probe: nil, repositoryReady: false,
            kitConfirmed: draft.progress.kitSaved)
    }

    var canContinue: Bool { SetupFlow.canContinue(from: step, facts: facts) }

    private func go(to next: SetupStep) {
        draft.go(to: next)
        if installed { store.save(draft.progress) }
    }

    // MARK: Move to Applications

    func refreshMoveDecision() {
        guard case .refused(let mover) = context else { return }
        moveDecision = mover.decision()
    }

    /// Moves, opens the moved copy and quits; on failure the screen shows why.
    func moveToApplications() async {
        guard case .refused(let mover) = context, !moving else { return }
        moving = true
        moveError = nil
        defer { moving = false }
        do {
            try await mover.move()
        } catch {
            moveError = AppMove.error(from: error).description
            moveDecision = mover.decision()
        }
    }

    // MARK: Permissions

    var notificationsAuthorised: Bool? {
        guard case .installed(let supervisor, _) = context else { return nil }
        return notificationsAnswer ?? supervisor.lastHello?.notificationsAuthorised
    }

    /// Asks the agent every `fullDiskAccessPollInterval` until the task is cancelled (the step's view goes).
    func pollFullDiskAccess() async {
        while !Task.isCancelled {
            await checkFullDiskAccess()
            try? await Task.sleep(for: Self.fullDiskAccessPollInterval)
        }
    }

    /// The agent's own probe (product spec §5.7), not the app's: the agent is what reads the files.
    func checkFullDiskAccess() async {
        guard case .installed(let supervisor, _) = context else { return }
        switch await supervisor.connection.probeFullDiskAccess() {
        case .success(let status):
            fullDiskAccessGranted = status.fdaMissing == false
            fullDiskAccessError = nil
        case .failure(let error):
            fullDiskAccessError = error.description
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(StatusItemController.fullDiskAccessURL)
    }

    /// The agent posts the alerts, so it asks (P2-8's pattern). A refusal shows as off, with the way to Settings.
    func requestNotifications() async {
        guard case .installed(let supervisor, _) = context, !requestingNotifications else { return }
        requestingNotifications = true
        defer { requestingNotifications = false }
        if case .success(let reply) = await supervisor.connection.requestNotificationPermission() {
            notificationsAnswer = reply.granted
        }
    }

    func openNotificationSettings() {
        guard case .installed(let supervisor, _) = context,
            let url = StatusItemController.notificationsURL(bundleID: supervisor.identity.agentBundleID)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Applies "Open at login" and goes on to storage.
    func continueFromPermissions() {
        guard step == .permissions, canContinue, case .installed(_, let loginItem) = context else { return }
        do {
            try loginItem.setEnabled(openAtLogin)
            loginItemError = nil
        } catch {
            loginItemError = "Restorey couldn't change Open at login: \(error.localizedDescription)"
            return
        }
        go(to: SetupFlow.next(after: step, facts: facts))
    }
}
