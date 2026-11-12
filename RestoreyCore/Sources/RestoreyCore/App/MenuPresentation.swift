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
        case .finishSetup: "Finish Setup…"
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
    /// 0 to 1 while a backup is running and restic has reported progress.
    public var progress: Double?
    public var destination: String
    public var severity: Severity?
    /// A button under the line ("Show details…" after a failed backup).
    public var action: BannerAction?
    /// Paused: the status is drawn grey (UI design §5), never as a failure.
    public var isPaused: Bool

    public init(
        id: UUID, name: String, status: String, detail: String? = nil, progress: Double? = nil,
        destination: String, severity: Severity? = nil, action: BannerAction? = nil, isPaused: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
        self.progress = progress
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
        health: AgentHealthState, status: AgentStatus?, notificationsAuthorised: Bool?, rates: [UUID: Double],
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
                return notAnswering(status: status, rates: rates, format: format)
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
            return healthy(status: status, notificationsAuthorised: notificationsAuthorised, rates: rates, format: format)
        }
    }

    // MARK: Healthy

    private static func healthy(
        status: AgentStatus, notificationsAuthorised: Bool?, rates: [UUID: Double], format: TextContext
    ) -> MenuContent {
        if let configError = status.configError {
            return MenuContent(icon: .error, message: "Restorey can't read its settings: \(configError)")
        }
        let banners = banners(status: status, notificationsAuthorised: notificationsAuthorised)
        let lines = status.plans.map { line(for: $0, rates: rates, format: format) }
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

    private static func line(
        for status: PlanStatus, rates: [UUID: Double], format: TextContext, suffix: String? = nil
    ) -> PlanLine {
        let plan = status.plan
        var line = PlanLine(
            id: plan.id, name: plan.name, status: "", destination: destination(status, format))
        switch status.phase {
        case .running(let progress, let retrying):
            line.status = "Backing up"
            line.progress = progress.map { min(max($0.percentDone, 0), 1) }
            line.detail = retrying.map { "Retrying: \($0)" } ?? runningDetail(progress, rate: rates[plan.id], format)
        case .paused(let until):
            line.status = "Paused"
            line.isPaused = true
            line.detail = "Resumes by itself at \(format.time(until))"
        case .idle, .skipped, .stopped:
            settled(status, into: &line, format)
        }
        if let suffix { line.status += " \(suffix)" }
        return line
    }

    private static func runningDetail(_ progress: BackupStatus?, rate: Double?, _ format: TextContext) -> String? {
        var parts: [String] = []
        if let progress {
            if progress.totalBytes > 0 {
                parts.append(DisplayFormat.progress(done: progress.bytesDone, of: progress.totalBytes, locale: format.locale))
            }
            if let seconds = progress.secondsRemaining { parts.append(DisplayFormat.remaining(seconds: seconds)) }
        }
        if let rate, rate > 0 { parts.append(DisplayFormat.rate(rate, locale: format.locale)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A plan that is not running or paused: what its last backup left, and anything wrong.
    private static func settled(_ status: PlanStatus, into line: inout PlanLine, _ format: TextContext) {
        let alerts = Set(status.alerts)
        if alerts.contains(.backupFailed) {
            let failed = status.lastRecord.flatMap { $0.outcome.failureReason == nil ? nil : $0 }
            line.status = failed.map { "Backup failed at \(format.time($0.endedAt))" } ?? "Backup failed"
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

        var details: [String] = []
        var severity: Severity?
        func flag(_ text: String, _ level: Severity) {
            details.append(text)
            severity = max(severity ?? level, level)
        }

        if let backup = status.lastBackup {
            line.status = "Backed up \(format.when(backup.endedAt))"
            if case .warning(let unreadable) = backup.outcome {
                flag("\(unreadable) \(unreadable == 1 ? "file" : "files") couldn't be read", .warning)
            }
        } else {
            line.status = status.setupState == .unfinished ? "Not backing up yet" : "No backup yet"
        }
        if case .skipped(let reason) = status.phase {
            if status.lastBackup == nil {
                line.status = reason.summary
            } else {
                details.insert(reason.summary, at: 0)
            }
            if reason != .agentUpdating { severity = max(severity ?? .warning, .warning) }
        }
        if alerts.contains(.checkInRejected) { flag("The check-in service rejected the last ping", .warning) }
        if alerts.contains(.checkFailed) { flag("The repository check failed", .error) }
        if alerts.contains(.configurationError) { flag("There's a problem with this plan's settings", .error) }

        if details.isEmpty, let next = status.nextRunAt { details = ["Next \(format.time(next))"] }
        line.detail = details.isEmpty ? nil : details.joined(separator: " · ")
        line.severity = severity
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
            if case .running(let progress?, _) = plan.phase, let seconds = progress.secondsRemaining {
                line.detail = "\(DisplayFormat.remaining(seconds: seconds)) left"
            }
            return line
        }
        return MenuContent(icon: .backingUp, plans: lines)
    }

    /// R68: the agent didn't answer but its last status is recent, so it is shown as it was, marked.
    private static func notAnswering(status: AgentStatus, rates: [UUID: Double], format: TextContext) -> MenuContent {
        let lines = status.plans.map { line(for: $0, rates: rates, format: format, suffix: "(agent not answering)") }
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

/// The inputs that shape text: the time, calendar and locale.
private struct TextContext {
    var now: Date
    var calendar: Calendar
    var locale: Locale

    func time(_ date: Date) -> String {
        DisplayFormat.time(date, calendar: calendar, locale: locale)
    }

    /// "at 14:16" today, "yesterday at 09:05", otherwise "9 Nov at 09:05".
    func when(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time(date))"
        }
        return "\(DisplayFormat.dayAndMonth(date, calendar: calendar, locale: locale)) at \(time(date))"
    }
}

private extension PlanPhase {
    var isRunning: Bool { if case .running = self { true } else { false } }
    var isPaused: Bool { if case .paused = self { true } else { false } }
    var isStopped: Bool { if case .stopped = self { true } else { false } }
}

private extension RunOutcome {
    /// The short reason for an outcome that is a failed backup, or nil for any other outcome.
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
