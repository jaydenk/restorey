import Foundation

/// A plan as Shortcuts and Siri list it (Task 17e, audit T2): its id and name only. Nothing secret, and nothing about
/// its repository, crosses an intent.
public struct ShortcutPlan: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Why a Shortcuts action can't do what was asked: one sentence, shown by Shortcuts as the action's error.
public struct ShortcutRefusal: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// What a Shortcuts action that changes something asks the agent for, and what it says once the agent has done it.
public struct ShortcutCall: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The menu's Back Up Now: one plan, or nil for every plan (the menu's "All Plans").
        case backUp(UUID?)
        /// The menu's Pause, for each plan in turn (the length is the action's own).
        case pause([UUID])
        /// The menu's Cancel Backup, for each running plan in turn.
        case cancel([UUID])
        /// The menu's Resume, for each plan in turn.
        case resume([UUID])
    }

    public var kind: Kind
    /// Said once every call succeeded.
    public var dialog: String

    public init(kind: Kind, dialog: String) {
        self.kind = kind
        self.dialog = dialog
    }
}

/// The last backup of a plan, as Get Last Backup returns it: values Shortcuts can use, and a sentence for Siri.
public struct LastBackupReport: Sendable, Equatable {
    public var planName: String
    /// When the newest backup ended, whatever its outcome; nil before the first.
    public var endedAt: Date?
    /// The History list's wording: "Backed up", "Backup failed", "Skipped: on battery power", … or "No backup yet".
    public var outcome: String
    /// The newest backup saved the data (success, unchanged or warning, Ruling P2-4).
    public var savedData: Bool
    /// When the newest backup that saved the data ended: what the menu's "Backed up at …" says.
    public var lastSavedAt: Date?
    /// "Home: Backed up — Today at 14:16", "Home: Backup failed — Yesterday at 09:05 (wrong password)".
    public var summary: String
}

/// The rules behind Restorey's Shortcuts actions (Task 17e, audit T2), pure so they are tested here. Each action does
/// exactly what the menu's item of the same name does, and only when the menu would let it: the enablement comes from
/// `MenuPresentation`'s `MenuActions`, the same value the menu is built from, so an action is refused exactly when the
/// menu's item is dimmed or missing. The menu only dims an item; an action can't, so it says why instead.
public enum ShortcutRules {
    /// How long an action waits for the agent's first answer when Restorey has only just opened (an action can launch
    /// it): the heartbeat's hello and the status fetch that follows normally take well under a second.
    public static let settleTimeout: Duration = .seconds(30)

    /// The menu waits too while it says "Connecting…" or "Updating…": an action asked then waits, up to
    /// `settleTimeout`, for the agent's answer rather than refusing at once.
    public static func isSettled(health: AgentHealthState, hasStatus: Bool) -> Bool {
        switch health {
        case .checking, .updating, .waitingForUpdate: false
        case .healthy: hasStatus
        case .switchedOff, .notRunning, .longWaitForRunningBackup, .damaged, .signatureUntrusted, .failed: true
        }
    }

    /// The plans Shortcuts offers, in the status's order (the menu's). An unreadable `config.json` has none.
    public static func plans(_ status: AgentStatus?) -> [ShortcutPlan] {
        guard let status, status.configError == nil else { return [] }
        return status.plans.map { ShortcutPlan(id: $0.plan.id, name: $0.plan.name) }
    }

    // MARK: Back Up Now, Pause, Resume

    /// `planID` nil: every plan, as the menu's Back Up Now (or its "All Plans") does.
    public static func backUp(
        planID: UUID?, health: AgentHealthState, content: MenuContent, status: AgentStatus?
    ) -> Result<ShortcutCall, ShortcutRefusal> {
        let actions = content.actions
        guard !actions.plans.isEmpty else { return .failure(unavailable(health: health, content: content, status: status)) }
        guard let planID else {
            guard actions.backUpNow else {
                let plans = status?.plans ?? []
                if !plans.isEmpty, plans.allSatisfy(\.phase.isRunning) {
                    return .failure(ShortcutRefusal("Restorey is already backing up."))
                }
                return .failure(ShortcutRefusal("No plan can back up now."))
            }
            return .success(ShortcutCall(kind: .backUp(nil), dialog: "Restorey is backing up."))
        }
        guard let (choice, plan) = find(planID, actions: actions, status: status) else { return .failure(gone) }
        guard choice.canBackUp else {
            if plan?.phase.isRunning == true { return .failure(ShortcutRefusal("“\(choice.name)” is already backing up.")) }
            return .failure(notReady(choice.name, plan) ?? ShortcutRefusal("“\(choice.name)” can’t back up now."))
        }
        return .success(ShortcutCall(kind: .backUp(planID), dialog: "Backing up “\(choice.name)”."))
    }

    /// The menu's Pause for `length`, after which the plan backs up by itself. `planID` nil: every plan the menu could
    /// pause, as its "All Plans" does.
    public static func pause(
        planID: UUID?, length: PauseLength, health: AgentHealthState, content: MenuContent, status: AgentStatus?
    ) -> Result<ShortcutCall, ShortcutRefusal> {
        let actions = content.actions
        guard !actions.plans.isEmpty else { return .failure(unavailable(health: health, content: content, status: status)) }
        guard let planID else {
            let plans = actions.plans.filter(\.canPause).map(\.id)
            guard !plans.isEmpty else { return .failure(ShortcutRefusal("Nothing is backing up, so there’s nothing to pause.")) }
            return .success(ShortcutCall(kind: .pause(plans), dialog: "Backups are paused \(spoken(length))."))
        }
        guard let (choice, plan) = find(planID, actions: actions, status: status) else { return .failure(gone) }
        guard choice.canPause else {
            switch plan?.phase {
            case .paused?: return .failure(ShortcutRefusal("“\(choice.name)” is already paused."))
            case .stopped?: return .failure(ShortcutRefusal("“\(choice.name)” is stopped, so there’s nothing to pause."))
            default:
                return .failure(notReady(choice.name, plan)
                    ?? ShortcutRefusal("“\(choice.name)” isn’t backing up, so there’s nothing to pause."))
            }
        }
        return .success(ShortcutCall(kind: .pause([planID]), dialog: "“\(choice.name)” is paused \(spoken(length))."))
    }

    /// How a dialog says how long: "for an hour" (not the menu's "for 1 hour"), "for 4 hours", "until tomorrow".
    private static func spoken(_ length: PauseLength) -> String {
        length == .oneHour ? "for an hour" : length.phrase
    }

    /// The menu's Cancel Backup: stops the run in progress, this run only. `planID` nil: every running plan, as its
    /// "All Plans" does.
    public static func cancel(
        planID: UUID?, health: AgentHealthState, content: MenuContent, status: AgentStatus?
    ) -> Result<ShortcutCall, ShortcutRefusal> {
        let actions = content.actions
        guard !actions.plans.isEmpty else { return .failure(unavailable(health: health, content: content, status: status)) }
        guard let planID else {
            let plans = actions.plans.filter(\.canCancel).map(\.id)
            guard !plans.isEmpty else { return .failure(ShortcutRefusal("There’s no backup to cancel.")) }
            return .success(ShortcutCall(kind: .cancel(plans), dialog: "Cancelled every backup in progress."))
        }
        guard let (choice, _) = find(planID, actions: actions, status: status) else { return .failure(gone) }
        guard choice.canCancel else { return .failure(ShortcutRefusal("“\(choice.name)” isn’t backing up.")) }
        return .success(ShortcutCall(kind: .cancel([planID]), dialog: "Cancelled the backup of “\(choice.name)”."))
    }

    /// What Cancel Backup says once the agent has answered for each plan: the call's own dialog, unless a pause was
    /// already stopping a run (`CancelOutcome.alreadyPausing`), in which case that plan wasn't cancelled and the dialog
    /// says why. An agent that doesn't say (`unknown`) keeps the call's wording.
    public static func cancelDialog(_ call: ShortcutCall, results: [(name: String, outcome: CancelOutcome)]) -> String {
        let pausing = results.filter { $0.outcome == .alreadyPausing }.map { "“\($0.name)”" }
        guard !pausing.isEmpty else { return call.dialog }
        let pauseSentence = "\(listed(pausing)) \(pausing.count == 1 ? "is" : "are") already pausing, so there was nothing to cancel."
        // The call's own sentence would claim the plans a pause won too, so name the others.
        let cancelled = results.filter { $0.outcome != .alreadyPausing }.map { "“\($0.name)”" }
        guard !cancelled.isEmpty else { return pauseSentence }
        return "Cancelled the \(cancelled.count == 1 ? "backup" : "backups") of \(listed(cancelled)). \(pauseSentence)"
    }

    /// "“A”", "“A” and “B”", "“A”, “B” and “C”".
    private static func listed(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// The menu's Resume, which also starts a backup at once (spec §3, Ruling R59). `planID` nil: every paused plan.
    public static func resume(
        planID: UUID?, health: AgentHealthState, content: MenuContent, status: AgentStatus?
    ) -> Result<ShortcutCall, ShortcutRefusal> {
        let actions = content.actions
        guard !actions.plans.isEmpty else { return .failure(unavailable(health: health, content: content, status: status)) }
        guard let planID else {
            let plans = actions.plans.filter(\.canResume).map(\.id)
            guard !plans.isEmpty else { return .failure(ShortcutRefusal("No plan is paused.")) }
            return .success(ShortcutCall(kind: .resume(plans), dialog: "Backups have resumed."))
        }
        guard let (choice, plan) = find(planID, actions: actions, status: status) else { return .failure(gone) }
        guard choice.canResume else {
            if let refusal = notReady(choice.name, plan), plan?.phase.isPaused == true { return .failure(refusal) }
            return .failure(ShortcutRefusal("“\(choice.name)” isn’t paused."))
        }
        return .success(ShortcutCall(kind: .resume([planID]), dialog: "“\(choice.name)” has resumed."))
    }

    /// What Back Up Now says when the agent answers that the plan was already backing up (it started between the
    /// status the rules read and the call).
    public static func alreadyBackingUp(planName: String?) -> String {
        planName.map { "“\($0)” is already backing up." } ?? "Restorey is already backing up."
    }

    /// Which of the menu's per-plan calls a multi-plan action made.
    public enum PerPlanAction: Sendable {
        case pause, resume, cancel
    }

    /// One plan's call in a multi-plan Pause or Resume: `failure` is the agent's or the connection's sentence.
    public struct PlanOutcome: Sendable, Equatable {
        public var planName: String
        public var failure: String?

        public init(planName: String, failure: String?) {
            self.planName = planName
            self.failure = failure
        }
    }

    /// The error for a Pause or Resume across several plans where some calls failed: each failed plan by name, with its
    /// reason, in the menu's alert wording ("Restorey couldn't pause …"), then the plans that did pause or resume, so a
    /// shortcut never leaves the person unsure which plans changed. Nil when every call succeeded. Every call is made
    /// whatever the earlier ones did, as the menu's "All Plans" does (`AgentActions`).
    public static func failureMessage(_ action: PerPlanAction, outcomes: [PlanOutcome]) -> String? {
        let failed = outcomes.filter { $0.failure != nil }
        guard !failed.isEmpty else { return nil }
        let verb = switch action {
        case .pause: "pause"
        case .resume: "resume"
        case .cancel: "cancel"
        }
        var sentences = failed.map { outcome in
            var reason = outcome.failure ?? ""
            if !reason.hasSuffix(".") { reason += "." }
            return "Restorey couldn’t \(verb) “\(outcome.planName)”: \(reason)"
        }
        let done = outcomes.filter { $0.failure == nil }.map { "“\($0.planName)”" }
        if !done.isEmpty {
            let names = done.count == 1 ? done[0] : done.dropLast().joined(separator: ", ") + " and " + done.last!
            let one = done.count == 1
            let sentence: String
            switch action {
            case .pause: sentence = "\(names) \(one ? "is" : "are") paused."
            case .resume: sentence = "\(names) \(one ? "has" : "have") resumed."
            case .cancel: sentence = "The \(one ? "backup" : "backups") of \(names) \(one ? "was" : "were") cancelled."
            }
            sentences.append(sentence)
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Get Last Backup

    /// The plan's newest backup, whatever its outcome, in the History list's words; `planID` nil: the newest backup of
    /// any plan, as the status item's tooltip has it. Reads only: nothing changes.
    public static func lastBackup(
        planID: UUID?, health: AgentHealthState, content: MenuContent, status: AgentStatus?,
        now: Date, calendar: Calendar, locale: Locale
    ) -> Result<LastBackupReport, ShortcutRefusal> {
        guard let status, status.configError == nil, !status.plans.isEmpty else {
            return .failure(unavailable(health: health, content: content, status: status))
        }
        let plan: PlanStatus
        if let planID {
            guard let found = status.plans.first(where: { $0.plan.id == planID }) else { return .failure(gone) }
            plan = found
        } else {
            let newest = status.plans.compactMap { plan in plan.latestBackupRecord.map { (plan, $0.endedAt) } }
                .max { $0.1 < $1.1 }?.0
            plan = newest ?? status.plans[0]
        }
        let name = plan.plan.name
        guard let record = plan.latestBackupRecord else {
            let outcome = plan.setupState == .unfinished ? "Not backing up yet" : "No backup yet"
            return .success(LastBackupReport(
                planName: name, endedAt: nil, outcome: outcome, savedData: false, lastSavedAt: nil,
                summary: "\(name): \(outcome)"))
        }
        let row = HistoryPresentation.row(record, planNames: [:], now: now, calendar: calendar, locale: locale)
        let format = TextContext(now: now, calendar: calendar, locale: locale)
        var summary = "\(name): \(row.outcome) — \(format.day(record.endedAt))"
        if let note = row.note { summary += " (\(note))" }
        return .success(LastBackupReport(
            planName: name, endedAt: record.endedAt, outcome: row.outcome, savedData: PlanRunHistory.savedData(record),
            lastSavedAt: plan.lastBackup?.endedAt, summary: summary))
    }

    // MARK: Helpers

    static let gone = ShortcutRefusal("That plan is no longer in Restorey.")

    /// Why nothing can be done at all: the menu's own words for the state (its banner, or its line while connecting or
    /// updating), so the action and the menu agree.
    static func unavailable(health: AgentHealthState, content: MenuContent, status: AgentStatus?) -> ShortcutRefusal {
        if health == .healthy {
            if status?.configError != nil { return ShortcutRefusal("Restorey can’t read its settings.") }
            if let status, !status.plans.isEmpty { return ShortcutRefusal("Restorey isn’t ready yet.") }
            return ShortcutRefusal("Restorey has no backup plans yet.")
        }
        if let banner = content.banners.first(where: { $0.planID == nil }) { return ShortcutRefusal(sentence(banner.title)) }
        if let message = content.message { return ShortcutRefusal(sentence(message)) }
        return ShortcutRefusal("Restorey isn’t ready yet.")
    }

    /// A plan that can't act because its setup isn't done: the menu line's words.
    private static func notReady(_ name: String, _ plan: PlanStatus?) -> ShortcutRefusal? {
        switch plan?.setupState {
        case .unfinished?: ShortcutRefusal("“\(name)” hasn’t finished setup.")
        case .needsNewKit?: ShortcutRefusal("“\(name)” needs a new recovery kit saved first.")
        default: nil
        }
    }

    /// The plan's menu choice and status; nil when the menu no longer lists it (deleted since the shortcut was made).
    private static func find(_ planID: UUID, actions: MenuActions, status: AgentStatus?) -> (PlanChoice, PlanStatus?)? {
        guard let choice = actions.plans.first(where: { $0.id == planID }) else { return nil }
        return (choice, status?.plans.first { $0.plan.id == planID })
    }

    /// A menu line as a sentence: its "…" becomes a full stop, and one is added if missing.
    private static func sentence(_ line: String) -> String {
        var text = line
        if text.hasSuffix("…") { text.removeLast() }
        return text.hasSuffix(".") ? text : text + "."
    }
}

private extension PlanPhase {
    var isRunning: Bool { if case .running = self { true } else { false } }
    var isPaused: Bool { if case .paused = self { true } else { false } }
}
