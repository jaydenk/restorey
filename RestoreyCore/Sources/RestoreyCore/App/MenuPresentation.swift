import Foundation

/// How bad a menu banner or plan line is. Warnings and errors both count toward the icon's worst state.
public enum Severity: Sendable, Comparable {
    case warning
    case error
}

/// What a banner's (or plan line's) button does. The UUID is the plan it is about.
public enum BannerAction: Sendable, Equatable {
    case openFullDiskAccess
    case restartAgent
    case openLoginItems
    case turnOnNotifications
    case addCheckInURL(UUID)
    case dismissOffMacNote(UUID)
    case finishSetup(UUID)
    /// No plan yet: opens setup where it was left (the window may have been closed).
    case setUp
    case saveRecoveryKit(UUID)
    case showDetails(UUID)

    /// The words on the banner's (or line's) button.
    public var buttonTitle: String {
        switch self {
        case .openFullDiskAccess: "Fix…"
        case .restartAgent: "Restart Agent"
        case .openLoginItems: "Open Login Items…"
        case .turnOnNotifications: "Turn On…"
        case .addCheckInURL: "Add…"
        case .dismissOffMacNote: "Don't Show This Again"
        case .finishSetup, .setUp: "Finish Setup…"
        case .saveRecoveryKit: "Save Recovery Kit…"
        case .showDetails: "Show Details…"
        }
    }
}

/// A problem shown at the top of the menu, with its fix.
public struct MenuBanner: Sendable, Equatable {
    public var severity: Severity
    public var title: String
    public var detail: String
    public var action: BannerAction
    /// A second button that sets the banner aside for good ("No off-Mac monitoring" only).
    public var dismiss: BannerAction?

    public init(severity: Severity, title: String, detail: String, action: BannerAction, dismiss: BannerAction? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.action = action
        self.dismiss = dismiss
    }
}

/// One plan's lines in the menu: its name, status, an optional second line and progress bar, and where it
/// backs up to.
public struct PlanLine: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var status: String
    public var detail: String?
    /// 0 to 1 while a backup is running and restic has reported progress, once it has finished counting the files.
    public var progress: Double?
    /// A backup is running but restic is still counting what there is to back up, so there is no fraction to show:
    /// the menu draws a bar with no end (Task 16e). Never set together with `progress`.
    public var isChecking: Bool
    public var destination: String
    public var severity: Severity?
    /// A button under the line ("Show details…" after a failed backup).
    public var action: BannerAction?
    /// Paused: the status is drawn grey (UI design §5), never as a failure.
    public var isPaused: Bool

    public init(
        id: UUID, name: String, status: String, detail: String? = nil, progress: Double? = nil,
        isChecking: Bool = false, destination: String, severity: Severity? = nil, action: BannerAction? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
        self.progress = progress
        self.isChecking = isChecking
        self.destination = destination
        self.severity = severity
        self.action = action
        self.isPaused = isPaused
    }
}

/// One plan in the menu's per-plan submenus, and what can be done to it now.
public struct PlanChoice: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var canBackUp: Bool
    public var canPause: Bool
    public var canResume: Bool
    /// Listed under Restore Files…: every plan but an unfinished one, which has no recovery kit and may have no
    /// repository yet.
    public var canRestore: Bool

    public init(id: UUID, name: String, canBackUp: Bool, canPause: Bool, canResume: Bool, canRestore: Bool) {
        self.id = id
        self.name = name
        self.canBackUp = canBackUp
        self.canPause = canPause
        self.canResume = canResume
        self.canRestore = canRestore
    }
}

/// Which of the menu's actions are enabled.
public struct MenuActions: Sendable, Equatable {
    public var backUpNow: Bool
    public var pause: Bool
    public var resume: Bool
    /// More than one plan: Back Up Now and Pause also get a submenu to act on one plan.
    public var perPlanSubmenus: Bool
    /// Every plan, in the status's order. Empty when the agent can't be asked to act (anything but healthy).
    public var plans: [PlanChoice]

    public init(backUpNow: Bool, pause: Bool, resume: Bool, perPlanSubmenus: Bool, plans: [PlanChoice] = []) {
        self.backUpNow = backUpNow
        self.pause = pause
        self.resume = resume
        self.perPlanSubmenus = perPlanSubmenus
        self.plans = plans
    }

    public static let none = MenuActions(backUpNow: false, pause: false, resume: false, perPlanSubmenus: false)
}

/// Everything the menu bar icon and menu show.
public struct MenuContent: Sendable, Equatable {
    public var icon: StatusIconState
    public var banners: [MenuBanner]
    public var plans: [PlanLine]
    public var actions: MenuActions
    /// A plain line for states with no plans to show: connecting, updating, the last known backup while the
    /// agent is down, a damaged installation, a settings file that can't be read.
    public var message: String?

    public init(
        icon: StatusIconState, banners: [MenuBanner] = [], plans: [PlanLine] = [], actions: MenuActions = .none,
        message: String? = nil
    ) {
        self.icon = icon
        self.banners = banners
        self.plans = plans
        self.actions = actions
        self.message = message
    }
}

/// Turns the agent's status into everything the menu shows (UI design §5). Pure: the same inputs give the
/// same content, so every state is tested without AppKit.
public enum MenuPresentation {
    /// How long after its last status an agent that stopped answering is shown as a warning (R68) rather
    /// than an error: long enough to cover a busy or restarting agent, short enough that a dead one is
    /// reported.
    public static let notAnsweringGrace: TimeInterval = 30 * 60

    public static func make(
        health: AgentHealthState, status: AgentStatus?, notificationsAuthorised: Bool?,
        now: Date, calendar: Calendar, locale: Locale
    ) -> MenuContent {
        let format = TextContext(now: now, calendar: calendar, locale: locale)
        switch health {
        case .checking:
            return MenuContent(icon: .ok, message: "Connecting to the background agent…")
        case .waitingForUpdate:
            return MenuContent(icon: .ok, message: "Updating the background agent…")
        case .updating:
            return updating(status: status, format: format)
        case .switchedOff:
            let banner = MenuBanner(
                severity: .error, title: "The background agent is switched off",
                detail: "No backups will happen.", action: .openLoginItems)
            return MenuContent(icon: .error, banners: [banner], message: lastKnown(status, format))
        case .notRunning(let reachable):
            // Only a backup that was running makes the silence plausible (R68). A status from the future (clock
            // skew) is not trusted either.
            if !reachable, let status, status.plans.contains(where: { $0.phase.isRunning }),
                (0...notAnsweringGrace).contains(now.timeIntervalSince(status.generatedAt))
            {
                return notAnswering(status: status, format: format)
            }
            let banner = MenuBanner(
                severity: .error, title: "The background agent isn't running",
                detail: "No backups will happen.", action: .restartAgent)
            return MenuContent(icon: .error, banners: [banner], message: lastKnown(status, format))
        case .damaged:
            return MenuContent(
                icon: .error, message: "Restorey's installation is damaged — reinstall it from the download")
        case .failed(let sentence):
            return MenuContent(icon: .error, message: sentence)
        case .healthy:
            // Healthy again, with the fresh status still on its way (`shouldRefetchStatus`).
            guard let status else { return MenuContent(icon: .ok, message: "Connecting to the background agent…") }
            return healthy(status: status, notificationsAuthorised: notificationsAuthorised, format: format)
        }
    }

    // MARK: Healthy

    private static func healthy(
        status: AgentStatus, notificationsAuthorised: Bool?, format: TextContext
    ) -> MenuContent {
        if let configError = status.configError {
            return MenuContent(icon: .error, message: "Restorey can't read its settings: \(configError)")
        }
        let banners = banners(status: status, notificationsAuthorised: notificationsAuthorised)
        let lines = status.plans.map { line(for: $0, format: format) }
        return MenuContent(
            icon: icon(banners: banners, plans: status.plans, lines: lines), banners: banners, plans: lines,
            actions: actions(status.plans), message: status.plans.isEmpty ? "No backup plans yet" : nil)
    }

    private static func icon(banners: [MenuBanner], plans: [PlanStatus], lines: [PlanLine]) -> StatusIconState {
        var icon = StatusIconState.ok
        for banner in banners { icon = max(icon, banner.severity == .error ? .error : .warning) }
        for (plan, line) in zip(plans, lines) {
            if let severity = line.severity { icon = max(icon, severity == .error ? .error : .warning) }
            switch plan.phase {
            case .running: icon = max(icon, .backingUp)
            case .paused: icon = max(icon, .paused)
            default: break
            }
        }
        return icon
    }

    private static func actions(_ plans: [PlanStatus]) -> MenuActions {
        let choices = plans.map { plan in
            let ready = plan.setupState == .complete
            return PlanChoice(
                id: plan.plan.id, name: plan.plan.name,
                canBackUp: ready && !plan.phase.isRunning,
                canPause: ready && !plan.phase.isPaused && !plan.phase.isStopped,
                canResume: ready && plan.phase.isPaused, canRestore: plan.setupState != .unfinished)
        }
        return MenuActions(
            backUpNow: choices.contains(where: \.canBackUp), pause: choices.contains(where: \.canPause),
            resume: choices.contains(where: \.canResume), perPlanSubmenus: plans.count > 1, plans: choices)
    }

    // MARK: Banners

    private static func banners(status: AgentStatus, notificationsAuthorised: Bool?) -> [MenuBanner] {
        var banners: [MenuBanner] = []
        if status.plans.isEmpty {
            banners.append(MenuBanner(
                severity: .warning, title: "Setup not finished",
                detail: "Set up a backup plan to start backing up this Mac.", action: .setUp))
        }
        let alerts = Set(status.plans.flatMap(\.alerts))
        // The probe's answer is the truth once it has run; a plan's alert stands in only before then.
        let fdaMissing = status.fdaMissing ?? alerts.contains(.fullDiskAccessMissing)
        if fdaMissing {
            banners.append(MenuBanner(
                severity: .error, title: "Full Disk Access is missing", detail: "Backups would be empty.",
                action: .openFullDiskAccess))
        }
        if notificationsAuthorised == false || alerts.contains(.notificationsOff) {
            banners.append(MenuBanner(
                severity: .warning, title: "Notifications are off — Restorey can't alert you",
                detail: "Turn them on so a problem with a backup reaches you.", action: .turnOnNotifications))
        }
        for plan in status.plans {
            switch plan.setupState {
            case .unfinished:
                banners.append(MenuBanner(
                    severity: .warning, title: "Setup not finished",
                    detail: scoped("Finish setting it up to start backing up.", plan.plan, of: status.plans.count),
                    action: .finishSetup(plan.plan.id)))
            case .needsNewKit:
                banners.append(MenuBanner(
                    severity: .warning, title: "New recovery kit needed",
                    detail: scoped("Save the new kit so backups can carry on.", plan.plan, of: status.plans.count),
                    action: .saveRecoveryKit(plan.plan.id)))
            case .complete:
                break
            }
            if !plan.plan.hasCheckInURL && !plan.plan.offMacNoteDismissed {
                banners.append(MenuBanner(
                    severity: .warning, title: "No off-Mac monitoring",
                    detail: scoped("Add a check-in URL so you hear if this Mac stops.", plan.plan, of: status.plans.count),
                    action: .addCheckInURL(plan.plan.id), dismiss: .dismissOffMacNote(plan.plan.id)))
            }
        }
        // Errors first, otherwise in the order found.
        return banners.enumerated()
            .sorted { ($0.element.severity, $1.offset) > ($1.element.severity, $0.offset) }
            .map(\.element)
    }

    /// With several plans, a banner says which one it is about.
    private static func scoped(_ sentence: String, _ plan: Plan, of count: Int) -> String {
        guard count > 1, let first = sentence.first else { return sentence }
        return "\(plan.name): \(first.lowercased())\(sentence.dropFirst())"
    }

    // MARK: Plan lines

    /// One plan's line as the menu shows it, for a window that follows one plan (setup's Done step).
    public static func planLine(
        for status: PlanStatus, now: Date, calendar: Calendar, locale: Locale
    ) -> PlanLine {
        return line(for: status, format: TextContext(now: now, calendar: calendar, locale: locale))
    }

    private static func line(
        for status: PlanStatus, format: TextContext, suffix: String? = nil
    ) -> PlanLine {
        let plan = status.plan
        var line = PlanLine(
            id: plan.id, name: plan.name, status: "", destination: destination(status, format))
        switch status.phase {
        case .running(let progress, let retrying):
            line.status = "Backing up"
            // While restic is still counting, its totals only grow: no fraction, no time left (Task 16e).
            if let progress {
                if progress.scanFinished {
                    line.progress = min(max(progress.percentDone, 0), 1)
                } else {
                    line.isChecking = true
                }
            }
            line.detail = retrying.map { "Retrying: \($0)" } ?? runningDetail(progress, format)
        case .paused(let until):
            line.status = "Paused"
            line.isPaused = true
            line.detail = Words.resumes(until, format)
        case .idle, .skipped, .stopped:
            settled(status, into: &line, format)
        }
        if let suffix { line.status += " \(suffix)" }
        return line
    }

    private static func runningDetail(_ progress: BackupStatus?, _ format: TextContext) -> String? {
        guard let progress else { return nil }
        guard progress.scanFinished else {
            return DisplayFormat.checkingForChanges(filesDone: progress.filesDone, locale: format.locale)
        }
        var parts: [String] = []
        if progress.totalBytes > 0 {
            parts.append(DisplayFormat.progress(done: progress.bytesDone, of: progress.totalBytes, locale: format.locale))
        }
        if let seconds = progress.secondsRemaining { parts.append(DisplayFormat.remaining(seconds: seconds)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A plan that is not running or paused: what its last backup left, and anything wrong.
    private static func settled(_ status: PlanStatus, into line: inout PlanLine, _ format: TextContext) {
        let alerts = Set(status.alerts)
        if alerts.contains(.backupFailed) {
            let failed = Words.failedBackup(status)
            line.status = Words.backupFailed(failed, format)
            if let reason = failed?.outcome.failureReason {
                line.detail = reason
            } else if case .stopped(let reason) = status.phase {
                line.detail = reason
            }
            line.severity = .error
            line.action = .showDetails(status.plan.id)
            return
        }
        if alerts.contains(.noRecentSuccess) {
            let days = status.plan.noSuccessAlertDays
            line.status = "No successful backup in \(days) \(days == 1 ? "day" : "days")"
            line.severity = .error
            // A skipped run is usually why nothing has succeeded.
            if case .skipped(let reason) = status.phase { line.detail = reason.summary }
            return
        }
        if case .stopped(let reason) = status.phase {
            line.status = "Stopped"
            line.detail = reason
            line.severity = .error
            return
        }

        let facts = settledFacts(status, format)
        line.status = facts.status
        // A skip with no backup yet is the status itself, so it isn't repeated in the detail.
        var details = facts.issues.filter { $0 != facts.status }
        if details.isEmpty, let next = status.nextRunAt { details = [Words.next(next, format)] }
        line.detail = details.isEmpty ? nil : details.joined(separator: " · ")
        line.severity = facts.severity
    }

    /// What a settled plan (no failure alert, not stopped) shows, apart from its next run: the status, what needs
    /// attention (a skip first, then warnings and errors) and how much. One source for the menu's plan line and the
    /// Overview's headline and reason, so a coloured Overview headline always has its reason (re-review N1).
    fileprivate struct SettledFacts {
        var status: String
        var issues: [String]
        var severity: Severity?
    }

    fileprivate static func settledFacts(_ status: PlanStatus, _ format: TextContext) -> SettledFacts {
        let alerts = Set(status.alerts)
        var facts = SettledFacts(status: Words.noBackup(status), issues: [], severity: nil)
        func flag(_ text: String, _ level: Severity) {
            facts.issues.append(text)
            facts.severity = max(facts.severity ?? level, level)
        }

        if let backup = status.lastBackup {
            facts.status = Words.backedUp(backup, format)
            if let unreadable = Words.unreadable(backup) { flag(unreadable, .warning) }
        }
        // A first backup that was cut short isn't lost: restic keeps what it uploaded and the next run carries on from it.
        if status.lastBackup == nil, case .idle = status.phase, let next = status.nextRunAt,
            let outcome = status.latestBackupRecord?.outcome, Words.interruptsFirstBackup(outcome)
        {
            facts.issues.append("The first backup was interrupted. It carries on at \(format.time(next)), keeping what's already uploaded.")
        }
        if case .skipped(let reason) = status.phase {
            if status.lastBackup == nil { facts.status = reason.summary }
            facts.issues.insert(reason.summary, at: 0)
            if reason != .agentUpdating { facts.severity = max(facts.severity ?? .warning, .warning) }
        }
        if alerts.contains(.checkInRejected) { flag("The check-in service rejected the last ping", .warning) }
        if alerts.contains(.checkFailed) { flag("The repository check failed", .error) }
        if alerts.contains(.configurationError) { flag("There's a problem with this plan's settings", .error) }
        return facts
    }

    // MARK: Destination

    /// "B2 · my-backups · 486 GB, 3 days ago": the size only once it has been measured.
    private static func destination(_ status: PlanStatus, _ format: TextContext) -> String {
        var text: String
        switch status.plan.repository {
        case .s3(let location):
            text = "\(location.provider == .b2 ? "B2" : "S3") · \(location.bucket)"
        case .raw(let repository, _):
            text = rawDestination(repository)
        }
        if let size = status.repositorySize {
            let age = DisplayFormat.age(of: size.measuredAt, now: format.now, calendar: format.calendar, locale: format.locale)
            text += " · \(DisplayFormat.size(size.bytes, locale: format.locale)), \(age)"
        }
        return text
    }

    private static let backendNames = [
        "azure": "Azure", "b2": "B2", "gs": "Google Cloud", "rclone": "rclone", "rest": "REST", "s3": "S3",
        "sftp": "SFTP", "swift": "Swift",
    ]

    private static func rawDestination(_ repository: String) -> String {
        if !Repository.rawLocationNeedsNetwork(repository) {
            let path = repository.hasPrefix("local:") ? String(repository.dropFirst("local:".count)) : repository
            return "Local · \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        let scheme = repository.prefix { $0 != ":" }
        return backendNames[String(scheme)] ?? "Remote repository"
    }

    // MARK: Updating and an agent that stopped answering

    private static func updating(status: AgentStatus?, format: TextContext) -> MenuContent {
        let running = (status?.plans ?? []).filter { $0.phase.isRunning }
        guard !running.isEmpty else {
            return MenuContent(icon: .ok, message: "Updating the background agent…")
        }
        let lines = running.map { plan -> PlanLine in
            var line = PlanLine(
                id: plan.plan.id, name: plan.plan.name,
                status: "Finishing the current backup before updating the agent", destination: destination(plan, format))
            // Time left means nothing until restic has finished counting (Task 16e).
            if case .running(let progress?, _) = plan.phase, progress.scanFinished, let seconds = progress.secondsRemaining {
                line.detail = "\(DisplayFormat.remaining(seconds: seconds)) left"
            }
            return line
        }
        return MenuContent(icon: .backingUp, plans: lines)
    }

    /// R68: the agent didn't answer but its last status is recent, so it is shown as it was, marked.
    private static func notAnswering(status: AgentStatus, format: TextContext) -> MenuContent {
        let lines = status.plans.map { line(for: $0, format: format, suffix: "(agent not answering)") }
        let banner = MenuBanner(
            severity: .warning, title: "The background agent isn't answering",
            detail: "Showing the last state it reported.", action: .restartAgent)
        let icon = max(.warning, icon(banners: [], plans: status.plans, lines: lines))
        return MenuContent(icon: icon, banners: [banner], plans: lines)
    }

    /// "Last known: backed up at 13:16", from the newest backup any plan reports.
    private static func lastKnown(_ status: AgentStatus?, _ format: TextContext) -> String? {
        guard let newest = status?.plans.compactMap(\.lastBackup).max(by: { $0.endedAt < $1.endedAt }) else { return nil }
        return "Last known: backed up \(format.when(newest.endedAt))"
    }
}

// MARK: - Helpers

/// The menu's words for a plan's backups, shared by its plan line and the Overview tab so neither has a copy.
private enum Words {
    static func backedUp(_ backup: RunRecord, _ format: TextContext) -> String {
        "Backed up \(format.when(backup.endedAt))"
    }

    /// The plan's newest backup verdict, when it failed with a reason.
    static func failedBackup(_ status: PlanStatus) -> RunRecord? {
        status.latestBackupVerdict.flatMap { $0.outcome.failureReason == nil ? nil : $0 }
    }

    static func backupFailed(_ failed: RunRecord?, _ format: TextContext) -> String {
        failed.map { "Backup failed at \(format.time($0.endedAt))" } ?? "Backup failed"
    }

    static func unreadable(_ backup: RunRecord) -> String? {
        guard case .warning(let unreadable) = backup.outcome else { return nil }
        return "\(unreadable) \(unreadable == 1 ? "file" : "files") couldn't be read"
    }

    /// A backup that ended without a verdict because something stopped it (the system, the user's pause, a crash).
    static func interruptsFirstBackup(_ outcome: RunOutcome) -> Bool {
        switch outcome {
        case .stoppedBySystem, .interrupted, .paused: true
        default: false
        }
    }

    static func noBackup(_ status: PlanStatus) -> String {
        status.setupState == .unfinished ? "Not backing up yet" : "No backup yet"
    }

    static func resumes(_ until: Date, _ format: TextContext) -> String {
        "Resumes by itself at \(format.time(until))"
    }

    static func next(_ date: Date, _ format: TextContext) -> String {
        "Next \(format.time(date))"
    }
}

// MARK: Overview

/// A plan's Overview tab in Settings (Task 14c, owner 15 Nov 2026; layout ruling R1). The headline is the plan's state
/// only ("Up to date", "Backing up — 42%", "Backup failed", "Stopped", …) with the menu's reason where it has one; the
/// times are only in the Last backup and Next backup rows, worded to follow their labels ("Today at 17:10"); and the
/// menu's actions for the plan, enabled as the menu's items are.
public struct PlanOverview: Sendable, Equatable {
    public struct Button: Sendable, Equatable {
        public enum Kind: Sendable, Hashable {
            case backUpNow
            case pause
            case resume
            case restoreFiles
        }

        public var kind: Kind
        public var enabled: Bool

        /// The menu item's title.
        public var title: String {
            switch kind {
            case .backUpNow: "Back Up Now"
            case .pause: "Pause"
            case .resume: "Resume"
            case .restoreFiles: "Restore Files…"
            }
        }
    }

    /// One of the two time rows: the value reads after its label ("Last backup: Today at 17:10").
    public struct Row: Sendable, Equatable {
        public var value: String
        public var detail: String?

        public init(value: String, detail: String?) {
            self.value = value
            self.detail = detail
        }
    }

    public struct CloudOnlyNote: Sendable, Equatable {
        /// The short line, "iCloud Drive files skipped".
        public var line: String
        /// What the info button's popover says.
        public var detail: String
        /// The info button's label for VoiceOver.
        public var accessibilityLabel: String

        public init(line: String, detail: String, accessibilityLabel: String) {
            self.line = line
            self.detail = detail
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// The plan's state, never a time.
    public var headline: String
    /// The menu's reason for the state: a failure's or a stop's cause, what needs attention, a backup's progress.
    public var reason: String?
    public var progress: Double?
    /// A backup is running but restic is still counting what there is to back up: a bar with no end, no percentage.
    public var isChecking = false
    /// The headline's colour. Set only when the plan itself needs attention, and then the reason (or the headline)
    /// says why.
    public var severity: Severity?
    public var isPaused: Bool
    public var lastBackup: Row?
    /// What the last backup skipped because the files exist only in the cloud: a short line and the detail behind its info button. Quiet
    /// information, never a warning; nil when nothing was skipped or not counted.
    public var cloudOnlyNote: CloudOnlyNote?
    /// Said once setup's choice to remove earlier snapshots has failed three backups in a row ("Couldn't remove the earlier
    /// snapshots you chose: <reason>. Restorey will try again after the next backup."). Information: no colour, and the menu
    /// icon is unchanged. Nil otherwise.
    public var earlierRemovalNote: String?
    /// The files the last backup couldn't read, for the "Show…" under the "N files couldn't be read" line (Task 16b). Set
    /// only where the reason carries that line (the settled headline, never a failure, a stop, a pause, a running backup
    /// or a plan waiting for a kit), and nil when the record kept no items (an older record). Information only.
    public var unreadable: UnreadableSummary?
    /// The last backup's biggest additions, under its row (Task 16d): only when it added more than 100 MB to the
    /// repository (`BiggestAdditionsText.overviewThreshold`), and, like the cloud-only note, while that backup is the one
    /// the row shows (not after a failure). Information only.
    public var biggestAdditions: BiggestAdditionsSummary?
    /// When the next backup is due, or when a pause ends; nil while one runs, while the plan is stopped or waits for
    /// a new kit, or when nothing is due.
    public var nextBackup: Row?
    /// Back Up Now, Pause while a backup runs, Resume while paused, Restore Files….
    public var buttons: [Button]
}

extension MenuPresentation {
    /// The Overview for `planID` from the same inputs as the menu (`make`): the plan's line and actions come from the
    /// menu's own content. Nil when the status doesn't list the plan.
    public static func overview(
        planID: UUID, health: AgentHealthState, status: AgentStatus?, notificationsAuthorised: Bool?,
        now: Date, calendar: Calendar, locale: Locale
    ) -> PlanOverview? {
        guard let plan = status?.plans.first(where: { $0.plan.id == planID }) else { return nil }
        let content = make(
            health: health, status: status, notificationsAuthorised: notificationsAuthorised, now: now,
            calendar: calendar, locale: locale)
        let format = TextContext(now: now, calendar: calendar, locale: locale)
        let choice = content.actions.plans.first { $0.id == planID }

        var overview = PlanOverview(
            headline: "", reason: nil, progress: nil, severity: nil, isPaused: false,
            lastBackup: lastBackupRow(plan, format), cloudOnlyNote: cloudOnlyNote(plan, locale: locale),
            earlierRemovalNote: earlierRemovalNote(plan),
            biggestAdditions: biggestAdditions(plan, locale: locale),
            nextBackup: nextBackupRow(plan, format), buttons: [])
        if let line = content.plans.first(where: { $0.id == planID }) {
            headline(plan, line, format, into: &overview)
        } else {
            // The agent can't be asked (not running, switched off, …): the menu's banner says why. Its colour is the
            // agent's, and its detail is the reason.
            let banner = content.banners.first
            overview.headline = banner?.title ?? content.message ?? ""
            overview.reason = banner?.detail
            overview.severity = banner?.severity
        }

        overview.buttons = [PlanOverview.Button(kind: .backUpNow, enabled: choice?.canBackUp ?? false)]
        if plan.phase.isRunning { overview.buttons.append(.init(kind: .pause, enabled: choice?.canPause ?? false)) }
        if plan.phase.isPaused { overview.buttons.append(.init(kind: .resume, enabled: choice?.canResume ?? false)) }
        overview.buttons.append(.init(kind: .restoreFiles, enabled: choice?.canRestore ?? false))
        return overview
    }

    /// The headline from the menu's facts for the plan: its phase and alerts, and its line's reason and severity. The
    /// colour is the plan line's own, never a banner's (a plan with no check-in URL has a warning banner in the menu,
    /// but nothing wrong with its backups: review R1 (b)).
    private static func headline(_ plan: PlanStatus, _ line: PlanLine, _ format: TextContext, into overview: inout PlanOverview) {
        let alerts = Set(plan.alerts)
        overview.severity = line.severity
        switch plan.phase {
        case .running:
            overview.headline = line.progress.map { "Backing up — \(Int(($0 * 100).rounded()))%" } ?? "Backing up"
            overview.progress = line.progress
            overview.isChecking = line.isChecking
            overview.reason = line.detail
            return
        case .paused:
            overview.headline = "Paused"
            overview.isPaused = true
            return
        case .idle, .skipped, .stopped:
            break
        }
        if alerts.contains(.backupFailed) {
            overview.headline = "Backup failed"
            overview.reason = line.detail
        } else if alerts.contains(.noRecentSuccess) {
            overview.headline = line.status
            overview.reason = line.detail
        } else if case .stopped = plan.phase {
            overview.headline = "Stopped"
            overview.reason = line.detail
        } else if plan.setupState == .needsNewKit {
            overview.headline = "Waiting for a new recovery kit"
            overview.severity = .warning
        } else {
            // The same facts as the menu's line, without its "Next …" (that time is the row's): every warning or
            // error is in the reason, a first run's skip included (re-review N1).
            let facts = settledFacts(plan, format)
            overview.reason = facts.issues.isEmpty ? nil : facts.issues.joined(separator: " · ")
            overview.severity = facts.severity
            // The items belong to the line `settledFacts` just put in the reason: the same record.
            if let last = plan.lastBackup, Words.unreadable(last) != nil { overview.unreadable = UnreadableSummary(record: last) }
            if facts.severity != nil {
                overview.headline = "Needs attention"
            } else {
                overview.headline = plan.lastBackup == nil ? Words.noBackup(plan) : "Up to date"
            }
        }
    }

    /// The newest backup's day and time. While the menu shows a failed backup (the `backupFailed` alert), so does the
    /// row, even when the failed run is no longer among the records the status carries (review minor 3).
    private static func lastBackupRow(_ plan: PlanStatus, _ format: TextContext) -> PlanOverview.Row {
        if plan.alerts.contains(.backupFailed) {
            let failed = Words.failedBackup(plan)
            return .init(value: failed.map { format.day($0.endedAt) } ?? "Not known", detail: "Failed")
        }
        if let backup = plan.lastBackup { return .init(value: format.day(backup.endedAt), detail: nil) }
        return .init(value: "None yet", detail: nil)
    }

    /// Under the last backup's row, while that backup is the one shown (not after a failure, whose row says "Failed").
    private static func cloudOnlyNote(_ plan: PlanStatus, locale: Locale) -> PlanOverview.CloudOnlyNote? {
        let count = plan.lastBackup?.cloudOnlySkipped
        guard !plan.alerts.contains(.backupFailed), let line = CloudOnlyText.line(count),
            let detail = CloudOnlyText.detail(count, locale: locale),
            let label = CloudOnlyText.accessibilityLabel(count)
        else { return nil }
        return .init(line: line, detail: detail, accessibilityLabel: label)
    }

    private static func biggestAdditions(_ plan: PlanStatus, locale: Locale) -> BiggestAdditionsSummary? {
        guard !plan.alerts.contains(.backupFailed), let backup = plan.lastBackup else { return nil }
        return BiggestAdditionsText.overviewSummary(record: backup, locale: locale)
    }

    private static func earlierRemovalNote(_ plan: PlanStatus) -> String? {
        guard var reason = plan.earlierRemovalProblem else { return nil }
        while reason.hasSuffix(".") { reason.removeLast() }
        return "Couldn't remove the earlier snapshots you chose: \(reason). Restorey will try again after the next backup."
    }

    private static func nextBackupRow(_ plan: PlanStatus, _ format: TextContext) -> PlanOverview.Row? {
        switch plan.phase {
        case .running, .stopped:
            return nil
        case .paused(let until):
            return .init(value: format.day(until), detail: "When the pause ends")
        case .idle, .skipped:
            guard plan.setupState == .complete else { return nil }
            return plan.nextRunAt.map { .init(value: format.day($0), detail: nil) }
        }
    }
}

// MARK: Schedule caption

extension MenuPresentation {
    /// The line under the Schedule tab's interval control (Task 16a): the plan's last backup and next run, as the menu
    /// words and times them ("Last backup at 14:16 · next at 15:16"). It describes the saved schedule; while the form
    /// has unsaved schedule edits it adds that the next run time changes when they are saved. A rule skipping the last attempt
    /// (battery, network, Wi-Fi, drive) is named beside the next run; the agent's own update is not a rule, so isn't.
    public static func scheduleCaption(
        _ status: PlanStatus, hasUnsavedScheduleEdits: Bool, now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        let format = TextContext(now: now, calendar: calendar, locale: locale)
        var parts = [status.lastBackup.map { "Last backup \(format.when($0.endedAt))" } ?? "No backup yet"]
        switch status.phase {
        case .running:
            parts.append("backing up now")
        case .paused(let until):
            parts.append("paused, resumes by itself \(format.when(until))")
        case .stopped:
            parts.append("stopped, so nothing is scheduled")
        case .idle, .skipped:
            if case .skipped(let reason) = status.phase, reason != .agentUpdating {
                // Mid-line, so not sentence-initial.
                parts.append(reason.summary.prefix(1).lowercased() + reason.summary.dropFirst())
            }
            switch status.setupState {
            case .unfinished: parts.append("setup isn't finished")
            case .needsNewKit: parts.append("waiting for a new recovery kit")
            case .complete:
                if let next = status.nextRunAt {
                    parts.append("\(status.lastBackup == nil ? "first" : "next") \(format.when(next))")
                } else {
                    parts.append("no next run")
                }
            }
        }
        let caption = parts.joined(separator: " · ")
        return hasUnsavedScheduleEdits ? caption + ". Next run time updates when you save." : caption
    }
}

/// The inputs that shape text: the time, calendar and locale.
private struct TextContext {
    var now: Date
    var calendar: Calendar
    var locale: Locale

    func time(_ date: Date) -> String {
        DisplayFormat.time(date, calendar: calendar, locale: locale)
    }

    /// "Today at 14:16", "Yesterday at 09:05", "Tomorrow at 09:00", otherwise "9 Nov at 09:05": a time that reads
    /// after a label (the Overview's rows).
    func day(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday at \(time(date))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow at \(time(date))"
        }
        return "\(DisplayFormat.dayAndMonth(date, calendar: calendar, locale: locale)) at \(time(date))"
    }

    /// "at 14:16" today, "yesterday at 09:05", "tomorrow at 09:00", otherwise "9 Nov at 09:05".
    func when(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time(date))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time(date))"
        }
        return "\(DisplayFormat.dayAndMonth(date, calendar: calendar, locale: locale)) at \(time(date))"
    }
}

private extension PlanPhase {
    var isRunning: Bool { if case .running = self { true } else { false } }
    var isPaused: Bool { if case .paused = self { true } else { false } }
    var isStopped: Bool { if case .stopped = self { true } else { false } }
}

extension RunOutcome {
    /// The short reason for an outcome that is a failure, or nil for any other outcome. The menu and the History
    /// list (`HistoryPresentation`) share it.
    var failureReason: String? {
        switch self {
        case .wrongPassword: "wrong password"
        case .repositoryMissing: "repository not found"
        case .credentialsUnavailable: "credentials unavailable"
        case .interrupted: "interrupted"
        case .failed(_, let reason): reason
        default: nil
        }
    }
}
