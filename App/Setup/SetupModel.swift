import AppKit
import Observation
import RestoreyCore
import SystemConfiguration

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

    /// Changed only here: the step extensions go through the named mutators under "The plan".
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
    /// Whether the setup window can be seen (`WindowRouter` follows its occlusion state). The Full Disk Access
    /// poll asks the agent only while it can.
    @ObservationIgnored var windowVisible = true
    /// P2-16: on by default; applied when the step is left with Continue. Saved in the progress as soon as it is
    /// switched, so the quit that granting Full Disk Access causes doesn't undo it.
    var openAtLogin: Bool {
        get { draft.progress.openAtLogin ?? defaultOpenAtLogin }
        set {
            draft.setOpenAtLogin(newValue)
            if installed { store.save(draft.progress) }
        }
    }
    @ObservationIgnored private let defaultOpenAtLogin: Bool
    private(set) var loginItemError: String?

    // Storage to Done: what the forms show, and the call in flight.
    var storage = StorageForm()
    /// Set once the plan is known (`loadPlan`): the schedule step's form.
    var schedule: ScheduleForm?
    /// The password step's "Use my own password" choice; the generated one is offered first.
    var ownPassword = false
    /// The host label chosen for an adopted repository (password step).
    var hostLabel = ""
    /// The schedule step's "Remove" for a check-in URL saved before setup was interrupted.
    var removeCheckInURL = false
    /// The adoption step's "Apply this plan's retention to existing snapshots from this Mac" before "Use This
    /// Repository" (SetupModel+EarlierSnapshots). Off by default; the confirmed choice itself is in the progress.
    var applyRetentionToEarlier = false
    /// What the opt-in found when it removes nothing (none beyond retention, or Cancel).
    var earlierNote: String?
    // Set by the step extensions (SetupModel+Storage, +Password, +Sources, +Schedule, +Done), which live in
    // their own files, so these setters are internal rather than private; the views only read them.
    /// What the step's last action reported, as a sentence; cleared when an action starts and on a step change.
    var stepError: String?
    /// A call to the agent is in flight: the step's buttons wait for it.
    var working = false
    /// Set by `loadPlan` when the first status read has no plan under the saved id (see `planMissing`).
    var planMissingAtLoad = false
    /// The password step's last probe failed (its sentence is `stepError`): "Try Again" probes again.
    var probeFailed = false
    /// Set when "Start first backup" has started the run: the records it is measured against.
    var firstBackupBaseline: FirstBackupProgress.Baseline?
    /// The recovery kit step's kit (`SetupModel+RecoveryKit`). It holds the plan's secrets, so it goes with the
    /// step: whenever the step changes and when the window closes.
    var recoveryKit: RecoveryKitModel?
    /// Closes the setup window (`WindowRouter` supplies it): Done's Close.
    @ObservationIgnored var closeWindow: (() -> Void)?
    /// Used for the secrets' keychain names before "Check" has saved a plan.
    @ObservationIgnored let newPlanID = UUID()

    /// The names this Mac may have recorded snapshots under; the first is a new plan's host label. Read once per
    /// window from System Configuration and `gethostname` (no name lookup on the network).
    @ObservationIgnored lazy var thisMacNames: [String] = {
        var buffer = [UInt8](repeating: 0, count: 256)
        let hostName = buffer.withUnsafeMutableBufferPointer { raw in
            raw.withMemoryRebound(to: CChar.self) { gethostname($0.baseAddress, $0.count) } == 0
        } ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : nil
        return SetupAdoption.thisMacNames(
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?, hostName: hostName)
    }()

    @ObservationIgnored private let context: Context
    @ObservationIgnored let store: SetupProgressStore

    init(context: Context, progress: SetupProgress, store: SetupProgressStore) {
        self.context = context
        self.store = store
        draft = SetupDraft(progress: progress)
        switch context {
        case .refused:
            defaultOpenAtLogin = true
        case .installed(let supervisor, let loginItem):
            fullDiskAccessGranted = supervisor.lastKnownStatus?.fdaMissing == false
            // Until switched here: off only when the user has switched Restorey off in Login Items.
            defaultOpenAtLogin = loginItem.status != .requiresApproval
        }
    }

    var installed: Bool {
        if case .installed = context { return true }
        return false
    }

    /// The window is closing: the step's secrets go now. The progress stays saved for the next opening.
    func close() {
        draft.close()
        closeRecoveryKit()
    }

    var facts: SetupFacts {
        SetupFacts(
            installed: installed, fdaGranted: fullDiskAccessGranted, probe: draft.probe,
            repositoryReady: repositoryReady, kitConfirmed: draft.progress.kitSaved)
    }

    var canContinue: Bool { SetupFlow.canContinue(from: step, facts: facts) }

    /// Saved only on a real step change, and only by the installed copy: a stray copy's move screen must not
    /// overwrite the installed copy's place in setup.
    func go(to next: SetupStep) {
        guard next != draft.step else { return }
        draft.go(to: next)
        closeRecoveryKit()
        stepError = nil
        if installed { store.save(draft.progress) }
    }

    // MARK: Move to Applications

    func refreshMoveDecision() async {
        guard case .refused(let mover) = context else { return }
        moveDecision = await mover.decision()
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
            moveDecision = await mover.decision()
        }
    }

    // MARK: Permissions

    /// What the agent last said in a hello: it holds the notification centre's answer (Ruling R68).
    var notificationsAuthorised: Bool? {
        guard case .installed(let supervisor, _) = context else { return nil }
        return supervisor.lastHello?.notificationsAuthorised
    }

    /// Every `fullDiskAccessPollInterval` while the window can be seen, until the task is cancelled (the step's
    /// view goes): Full Disk Access, and the notification answer with it, which the user may change in Settings.
    func pollPermissions() async {
        while !Task.isCancelled {
            if windowVisible { await checkPermissions() }
            try? await Task.sleep(for: Self.fullDiskAccessPollInterval)
        }
    }

    /// Also run whenever Restorey comes back to the front, visible or not.
    func checkPermissions() async {
        await checkFullDiskAccess()
        await refreshNotifications()
    }

    private func refreshNotifications() async {
        guard case .installed(let supervisor, _) = context else { return }
        await supervisor.refreshHello()
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
        _ = await supervisor.connection.requestNotificationPermission()
        await refreshNotifications()
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
            loginItemError = "Restorey couldn’t change Open at login: \(error.localizedDescription)"
            return
        }
        go(to: SetupFlow.next(after: step, facts: facts))
    }

    // MARK: The plan (shared by the steps)

    var supervisor: AgentSupervisor? {
        if case .installed(let supervisor, _) = context { return supervisor }
        return nil
    }

    var plan: Plan? { draft.plan }

    /// The plan this setup saved is gone from the agent (deleted elsewhere, while the window was closed or open):
    /// the steps can't go on, and the window offers to start again (`startAgain`). A status with a settings error
    /// lists no plans, so it never counts.
    /// The agent can't read its settings, so its status lists no plans: the window shows why and waits for a
    /// status that has them, never offering to start again (that would orphan the plan once the file is fixed).
    /// From the latest status, so a file that becomes unreadable while the window is open shows it too.
    var configError: String? { supervisor?.status?.configError }

    var planMissing: Bool {
        if planMissingAtLoad { return true }
        guard let id = draft.progress.planID, let status = supervisor?.status, status.configError == nil else {
            return false
        }
        return !status.plans.contains { $0.plan.id == id }
    }

    /// The plan's id: the saved plan's, or the one "Check" will save a new plan under.
    var planID: UUID { draft.plan?.id ?? draft.progress.planID ?? newPlanID }

    /// The plan's latest status from the agent, for Done's progress.
    var planStatus: PlanStatus? {
        supervisor?.status?.plans.first { $0.plan.id == planID }
    }

    /// A resumed setup gets the plan back from the agent's status (the plan was saved at each Continue).
    /// Waits for the first status when there is none yet. A first run with no plan saved has nothing to load.
    /// A status without the plan (deleted elsewhere) sets `planMissing`; with a settings error the wait goes on.
    ///
    /// The wait isn't woken by cancellation: a step view that goes while it waits leaves this task parked until
    /// the next status arrives, when it sees the cancellation and returns without touching anything. Statuses
    /// arrive with every heartbeat, so it doesn't stay parked for long.
    func loadPlan() async {
        guard draft.plan == nil, let id = draft.progress.planID, let supervisor else { return }
        while !Task.isCancelled, draft.plan == nil {
            if let status = supervisor.lastKnownStatus {
                if status.configError != nil {
                    // No plans are listed while the settings can't be read (`configError` shows why): wait for a
                    // status that can say.
                } else if let saved = status.plans.first(where: { $0.plan.id == id })?.plan {
                    draft.plan = saved
                    storage = StorageForm(repository: saved.repository)
                    hostLabel = saved.hostLabel
                    return
                } else {
                    planMissingAtLoad = true
                    return
                }
            }
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = supervisor.lastKnownStatus
                } onChange: {
                    resume.resume()
                }
            }
        }
    }

    /// After `planMissing`: forget the plan and go back to the storage step with an empty form.
    func startAgain() {
        draft.forgetPlan()
        closeRecoveryKit()
        planMissingAtLoad = false
        probeFailed = false
        storage = StorageForm()
        schedule = nil
        stepError = nil
        firstBackupBaseline = nil
        if installed { store.save(draft.progress) }
    }

    // Named changes to the draft, for the step extensions. Those that record a fact setup must keep across a quit
    // save the progress at once.

    func setProbe(_ probe: RepositoryProbe?) {
        draft.probe = probe
        if probe != nil { probeFailed = false }
    }

    /// "Check" saved the plan under `id`.
    func recordSavedPlan(_ id: UUID) {
        draft.setPlanID(id)
        saveProgress()
    }

    /// "Check" saved a different address: nothing found, created or adopted at the old one holds.
    func forgetRepository() {
        draft.forgetRepository()
        probeFailed = false
        saveProgress()
    }

    func recordRepositoryCreated() {
        draft.setRepositoryCreated()
        saveProgress()
    }

    func recordAdoption(_ report: AdoptReport) {
        draft.setAdoption(report)
        saveProgress()
    }

    func recordEarlierRemoval(_ confirmation: EarlierSnapshotsConfirmation?) {
        draft.setEarlierRemoval(confirmation)
        saveProgress()
    }

    var kitSaved: Bool {
        get { draft.progress.kitSaved }
        set {
            draft.setKitSaved(newValue)
            saveProgress()
        }
    }

    /// The sources step's edits to the plan, saved at its Continue.
    func editPlan(_ change: (inout Plan) -> Void) {
        guard var plan = draft.plan else { return }
        change(&plan)
        draft.plan = plan
    }

    private func saveProgress() {
        if installed { store.save(draft.progress) }
    }

    func secret(_ key: SecretKey) -> String { draft.secret(key) ?? "" }

    /// Stores what was typed as it is (the fields' binding rule): empty is no secret.
    func setSecret(_ value: String, for key: SecretKey) {
        draft.setSecret(value.isEmpty ? nil : value, for: key)
    }

    /// An environment row's typed value, held by row until "Check" names its keychain item.
    func environmentValue(_ row: UUID) -> String { draft.environmentValue(row) ?? "" }

    /// Stores what was typed as it is (the fields' binding rule): empty is no value.
    func setEnvironmentValue(_ value: String, for row: UUID) {
        draft.setEnvironmentValue(value.isEmpty ? nil : value, for: row)
    }

    /// Runs `body` as the step's one action: the buttons wait, and a sentence it returns is shown.
    func act(_ body: () async -> String?) async {
        guard !working else { return }
        working = true
        stepError = nil
        let problem = await body()
        working = false
        stepError = problem.map(FormValidation.sentence)
    }

    /// Saves `plan` and `secrets` through the agent and keeps the saved plan (normalised by the agent). Nil,
    /// or the agent's sentence.
    func save(_ plan: Plan, secrets: [SecretEntry] = []) async -> String? {
        guard let supervisor else { return "Restorey isn’t installed" }
        switch await supervisor.connection.savePlan(SavePlanRequest(plan: plan, secrets: secrets)) {
        case .success(let status):
            draft.plan = status.plans.first { $0.plan.id == plan.id }?.plan ?? plan
            return nil
        case .failure(let error):
            return error.description
        }
    }

    func closeSetupWindow() {
        closeWindow?()
    }
}
