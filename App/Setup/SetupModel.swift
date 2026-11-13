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
    /// What the step's last action reported, as a sentence; cleared when an action starts and on a step change.
    private(set) var stepError: String?
    /// A call to the agent is in flight: the step's buttons wait for it.
    private(set) var working = false
    /// True once the repository has been created, or adopted, by this setup (`SetupFacts.repositoryReady`).
    private(set) var repositoryReady = false
    /// Set when "Start first backup" has started the run: the records it is measured against.
    private(set) var firstBackupBaseline: FirstBackupProgress.Baseline?
    /// Closes the setup window (`WindowRouter` supplies it): Done's Close.
    @ObservationIgnored var closeWindow: (() -> Void)?
    /// Used for the secrets' keychain names before "Check" has saved a plan.
    @ObservationIgnored private let newPlanID = UUID()

    @ObservationIgnored private let context: Context
    @ObservationIgnored private let store: SetupProgressStore

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
    }

    private var facts: SetupFacts {
        SetupFacts(
            installed: installed, fdaGranted: fullDiskAccessGranted, probe: draft.probe,
            repositoryReady: repositoryReady, kitConfirmed: draft.progress.kitSaved)
    }

    var canContinue: Bool { SetupFlow.canContinue(from: step, facts: facts) }

    /// Saved only on a real step change, and only by the installed copy: a stray copy's move screen must not
    /// overwrite the installed copy's place in setup.
    private func go(to next: SetupStep) {
        guard next != draft.step else { return }
        draft.go(to: next)
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
            loginItemError = "Restorey couldn't change Open at login: \(error.localizedDescription)"
            return
        }
        go(to: SetupFlow.next(after: step, facts: facts))
    }

    // MARK: The plan

    private var supervisor: AgentSupervisor? {
        if case .installed(let supervisor, _) = context { return supervisor }
        return nil
    }

    var plan: Plan? { draft.plan }

    /// The plan's id: the saved plan's, or the one "Check" will save a new plan under.
    var planID: UUID { draft.plan?.id ?? draft.progress.planID ?? newPlanID }

    /// The plan's latest status from the agent, for Done's progress and the upload speed.
    var planStatus: PlanStatus? {
        supervisor?.status?.plans.first { $0.plan.id == planID }
    }

    var bytesPerSecond: Double? { supervisor?.rates.bytesPerSecond[planID] }

    /// A resumed setup gets the plan back from the agent's status (the plan was saved at each Continue).
    /// Waits for the first status when there is none yet. A first run with no plan saved has nothing to load.
    func loadPlan() async {
        guard draft.plan == nil, let id = draft.progress.planID, let supervisor else { return }
        while !Task.isCancelled, draft.plan == nil {
            if let status = supervisor.lastKnownStatus {
                guard let saved = status.plans.first(where: { $0.plan.id == id })?.plan else { return }
                draft.plan = saved
                storage = StorageForm(repository: saved.repository)
                hostLabel = saved.hostLabel
                return
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

    func secret(_ key: SecretKey) -> String { draft.secret(key) ?? "" }

    /// Stores what was typed as it is (the fields' binding rule): empty is no secret.
    func setSecret(_ value: String, for key: SecretKey) {
        draft.setSecret(value.isEmpty ? nil : value, for: key)
    }

    /// Runs `body` as the step's one action: the buttons wait, and a sentence it returns is shown.
    private func act(_ body: () async -> String?) async {
        guard !working else { return }
        working = true
        stepError = nil
        let problem = await body()
        working = false
        stepError = problem.map(FormValidation.sentence)
    }

    /// Saves `plan` and `secrets` through the agent and keeps the saved plan (normalised by the agent). Nil,
    /// or the agent's sentence.
    private func save(_ plan: Plan, secrets: [SecretEntry] = []) async -> String? {
        guard let supervisor else { return "Restorey isn't installed" }
        switch await supervisor.connection.savePlan(SavePlanRequest(plan: plan, secrets: secrets)) {
        case .success(let status):
            draft.plan = status.plans.first { $0.plan.id == plan.id }?.plan ?? plan
            return nil
        case .failure(let error):
            return error.description
        }
    }

    // MARK: Storage

    /// The names this Mac may have recorded snapshots under; the first is a new plan's host label. Read once per
    /// window from System Configuration and `gethostname` (no name lookup on the network).
    @ObservationIgnored private lazy var thisMacNames: [String] = {
        var buffer = [UInt8](repeating: 0, count: 256)
        let hostName = buffer.withUnsafeMutableBufferPointer { raw in
            raw.withMemoryRebound(to: CChar.self) { gethostname($0.baseAddress, $0.count) } == 0
        } ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : nil
        return SetupAdoption.thisMacNames(
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?, hostName: hostName)
    }()

    /// "Check": saves the plan (its kit unconfirmed, so it never runs) with the backend's secrets, then asks
    /// the agent what is at the address (Ruling P2-2). A new plan, or one whose address changed, gets a
    /// generated stand-in password for the probe: restic needs one even to find nothing, and a repository
    /// that is there refuses it (`.passwordRejected`), which is how setup learns one is there. The password
    /// step replaces it.
    func check() async {
        guard step == .storage, let repository = storage.repositoryValue, let supervisor else { return }
        await act {
            let id = planID
            let sameRepository = draft.plan?.repository == repository
            let typed: [SecretEntry]
            switch storage.secretEntries(planID: id, typed: { self.draft.secret($0) }, saved: sameRepository) {
            case .failure(let problem): return problem.message
            case .success(let entries): typed = entries
            }
            var plan: Plan
            var secrets = typed
            if var saved = draft.plan {
                saved.repository = repository
                if !sameRepository { saved.name = StorageForm.planName(for: repository) }
                plan = saved.origin == .created ? SetupAdoption.created(saved) : saved
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser
                plan = Plan.newHotPlan(
                    name: StorageForm.planName(for: repository), repository: repository, origin: .created,
                    hostLabel: thisMacNames.first ?? "Mac", sources: [home.path],
                    exclusions: DefaultExclusions.paths(home: home, identity: supervisor.identity), now: Date())
                plan.id = id
            }
            if !sameRepository {
                secrets.append(SecretEntry(key: .repositoryPassword(id), value: PasswordGenerator.make()))
            }
            if let problem = await save(plan, secrets: secrets) { return problem }
            draft.setPlanID(id)
            store.save(draft.progress)
            switch await supervisor.connection.probeRepository(id) {
            case .failure(let error):
                return error.description
            case .success(let probe):
                draft.probe = probe
                repositoryReady = false
                if case .existing(let report) = probe.state { hostLabel = defaultHostLabel(report) }
                go(to: .password)
                return nil
            }
        }
    }

    // MARK: Password

    /// The password step shows what "Check" found; a resumed step probes again with the saved password.
    func probeIfNeeded() async {
        guard step == .password, draft.probe == nil, let plan = draft.plan, let supervisor else { return }
        await act {
            switch await supervisor.connection.probeRepository(plan.id) {
            case .failure(let error): return error.description
            case .success(let probe):
                draft.probe = probe
                if case .existing(let report) = probe.state {
                    // Opened by the saved password: one this setup created, or one whose password was entered.
                    repositoryReady = plan.origin == .created
                    hostLabel = plan.origin == .adopted ? plan.hostLabel : defaultHostLabel(report)
                }
                return nil
            }
        }
    }

    /// The generated password offered for a new repository, made the first time the step shows it.
    func offerGeneratedPassword() {
        let key = SecretKey.repositoryPassword(planID)
        if draft.secret(key) == nil { draft.setSecret(PasswordGenerator.make(), for: key) }
    }

    func newGeneratedPassword() {
        draft.setSecret(PasswordGenerator.make(), for: .repositoryPassword(planID))
    }

    /// Switching between the generated password and the user's own starts the field afresh. The recovery kit,
    /// next, shows the password as saved, so a mistyped one is seen there before anything is backed up.
    func chooseOwnPassword(_ own: Bool) {
        ownPassword = own
        draft.setSecret(own ? nil : PasswordGenerator.make(), for: .repositoryPassword(planID))
    }

    var passwordProblem: String? {
        secret(.repositoryPassword(planID)).isEmpty ? "Enter a password for the repository." : nil
    }

    /// "Create new repository" (product spec §5.4: never automatic): saves the password, then `restic init`.
    func createRepository() async {
        guard step == .password, draft.probe == .some(RepositoryProbe(state: .empty)), passwordProblem == nil,
            let saved = draft.plan, let supervisor
        else { return }
        await act {
            let password = SecretEntry(key: .repositoryPassword(saved.id), value: secret(.repositoryPassword(saved.id)))
            if let problem = await save(SetupAdoption.created(saved), secrets: [password]) { return problem }
            switch await supervisor.connection.createRepository(saved.id) {
            case .failure(let error): return error.description
            case .success:
                repositoryReady = true
                go(to: .recoveryKit)
                return nil
            }
        }
    }

    /// The existing repository's "Open": saves the password typed, then probes with it.
    func openExistingRepository() async {
        let key = SecretKey.repositoryPassword(planID)
        guard step == .password, let saved = draft.plan, let supervisor, !secret(key).isEmpty else { return }
        await act {
            if let problem = await save(saved, secrets: [SecretEntry(key: key, value: secret(key))]) { return problem }
            draft.setSecret(nil, for: key)
            switch await supervisor.connection.probeRepository(saved.id) {
            case .failure(let error): return error.description
            case .success(let probe):
                draft.probe = probe
                switch probe.state {
                case .existing(let report):
                    hostLabel = defaultHostLabel(report)
                    return nil
                case .passwordRejected: return "That password doesn't open the repository at this address"
                case .empty: return "The repository is no longer there: create a new one, or go back and check the address"
                }
            }
        }
    }

    var hostChoices: [String] {
        guard case .existing(let report)? = draft.probe?.state else { return [] }
        return SetupAdoption.hostChoices(hosts: report.hosts, thisMac: thisMacNames)
    }

    private func defaultHostLabel(_ report: AdoptReport) -> String {
        SetupAdoption.defaultHostLabel(hosts: report.hosts, thisMac: thisMacNames)
    }

    /// "Use this repository": the plan becomes an adopted one under the chosen host label, `adopt` lists its
    /// snapshots for that label, and the sources are pre-filled from the latest one (product spec §5.4).
    func useExistingRepository() async {
        guard step == .password, case .existing? = draft.probe?.state, let saved = draft.plan, let supervisor,
            FormValidation.hostLabel(hostLabel) == nil
        else { return }
        await act {
            let adopted = SetupAdoption.adopted(saved, hostLabel: hostLabel.trimmingCharacters(in: .whitespaces))
            if let problem = await save(adopted) { return problem }
            switch await supervisor.connection.adopt(saved.id) {
            case .failure(let error): return error.description
            case .success(let report):
                draft.adoption = report
                var prefilled = draft.plan ?? adopted
                prefilled.sources = SetupAdoption.prefilledSources(report, current: prefilled.sources)
                if let problem = await save(prefilled) { return problem }
                repositoryReady = true
                go(to: .recoveryKit)
                return nil
            }
        }
    }

    /// The password step's Continue, for a repository a resumed setup finds ready.
    func continueFromPassword() {
        guard step == .password, canContinue else { return }
        go(to: SetupFlow.next(after: step, facts: facts))
    }

    /// Back to the storage form, to correct the address.
    func backToStorage() {
        guard step == .password, !working else { return }
        draft.probe = nil
        repositoryReady = false
        go(to: .storage)
    }

    // MARK: Recovery kit

    var kitSaved: Bool {
        get { draft.progress.kitSaved }
        set {
            draft.setKitSaved(newValue)
            if installed { store.save(draft.progress) }
        }
    }

    func continueFromRecoveryKit() {
        guard step == .recoveryKit, canContinue else { return }
        go(to: SetupFlow.next(after: step, facts: facts))
    }

    // MARK: Sources

    var sources: [String] {
        get { draft.plan?.sources ?? [] }
        set { draft.plan?.sources = newValue }
    }

    var exclusions: [String] {
        get { draft.plan?.exclusions ?? [] }
        set { draft.plan?.exclusions = newValue }
    }

    var fileTypeExclusions: [String] {
        get { draft.plan?.fileTypeExclusions ?? [] }
        set { draft.plan?.fileTypeExclusions = newValue }
    }

    var oneFileSystem: Bool {
        get { draft.plan?.oneFileSystem ?? true }
        set { draft.plan?.oneFileSystem = newValue }
    }

    /// The build's identity, for the default exclusions (Restorey's own folders differ per identity).
    var identity: Identity? { supervisor?.identity }

    /// The new-group warning for an adopted repository (product spec §5.4).
    var sourcesWarning: String? {
        guard let plan = draft.plan, plan.origin == .adopted, let report = draft.adoption else { return nil }
        return SetupAdoption.newGroupWarning(hostLabel: plan.hostLabel, sources: plan.sources, report: report)
    }

    var sourcesProblem: String? { sources.isEmpty ? "Add at least one folder or drive to back up." : nil }

    func continueFromSources() async {
        guard step == .sources, sourcesProblem == nil, let plan = draft.plan else { return }
        await act {
            if let problem = await save(plan) { return problem }
            if schedule == nil, let saved = draft.plan { schedule = ScheduleForm(plan: saved) }
            go(to: .schedule)
            return nil
        }
    }

    // MARK: Schedule

    /// The form starts from the plan as saved (a resumed setup, or after the sources step).
    func prepareSchedule() {
        if schedule == nil, let plan = draft.plan { schedule = ScheduleForm(plan: plan) }
    }

    var checkInProblem: String? { ScheduleForm.checkInProblem(secret(.checkInURL(planID))) }

    var scheduleProblem: String? {
        guard let schedule else { return nil }
        if case .failure(let problem) = schedule.retention { return problem.message }
        return checkInProblem
    }

    func continueFromSchedule() async {
        guard step == .schedule, let schedule, scheduleProblem == nil, let saved = draft.plan else { return }
        await act {
            guard case .success(var plan) = schedule.applied(to: saved) else { return nil }
            let intent: CheckInIntent
            do {
                // "Remove" then a new URL typed is a replacement, not both at once.
                let field = secret(.checkInURL(plan.id))
                intent = try checkInIntent(
                    existing: plan.hasCheckInURL, field: field, remove: removeCheckInURL && field.isEmpty)
            } catch {
                return "\(error)"
            }
            plan.hasCheckInURL = intent.hasCheckInURL
            let secrets = intent.secret.map { [SecretEntry(key: .checkInURL(plan.id), value: $0)] } ?? []
            if let problem = await save(plan, secrets: secrets) { return problem }
            removeCheckInURL = false
            go(to: .done)
            return nil
        }
    }

    // MARK: Done

    var firstBackup: FirstBackupProgress? {
        guard let firstBackupBaseline else { return nil }
        return FirstBackupProgress.make(
            plan: planStatus, baseline: firstBackupBaseline, bytesPerSecond: bytesPerSecond, now: Date(),
            calendar: .current, locale: .current)
    }

    /// "Start first backup": saves anything not yet saved, confirms the recovery kit (deferred from its step
    /// so the plan couldn't run mid-setup, `SetupFlow`), then starts the backup. The plan is complete from
    /// the confirmation on, so the saved progress goes: there is nothing left to resume.
    func startFirstBackup() async {
        guard step == .done, draft.progress.kitSaved, let plan = draft.plan, let supervisor else { return }
        await act {
            if planStatus?.plan != plan, let problem = await save(plan) { return problem }
            let baseline = FirstBackupProgress.Baseline(planStatus)
            switch await supervisor.connection.confirmRecoveryKit(plan.id) {
            case .failure(let error): return error.description
            case .success: store.clear()
            }
            // Confirming makes the plan runnable and due (it has never backed up), so the scheduler may start
            // it before Back Up Now arrives, which the agent then refuses as already running. Either way the
            // first backup is running: that is decided from the plan's phase, not from the refusal's text.
            let started = await supervisor.connection.backUpNow(plan.id)
            if case .failure(let error) = started, !(planStatus?.phase.isRunning ?? false) { return error.description }
            firstBackupBaseline = baseline
            return nil
        }
    }

    func closeSetupWindow() {
        closeWindow?()
    }
}

private extension PlanPhase {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
