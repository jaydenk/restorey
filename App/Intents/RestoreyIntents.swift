import AppIntents
import RestoreyCore

// Restorey's Shortcuts actions (Task 17e, audit T2): Back Up Now, Pause Backups, Cancel Backup, Resume Backups and Get Last Backup, in
// the Shortcuts app and Spotlight with no other UI (not Siri voice: App Shortcuts can't be invoked by voice on macOS).
// Each runs in the background (`supportedModes`), does what the menu's item of the same name does through the same XPC
// calls, and is refused when the menu would refuse it (`ShortcutRules`, tested in RestoreyCore). Only plan ids and names cross an intent, never a secret.

/// A backup plan, as Shortcuts lists it.
struct PlanEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Backup Plan"
    static let defaultQuery = PlanEntityQuery()

    let id: UUID
    @Property(title: "Name") var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(_ plan: ShortcutPlan) {
        self.init(id: plan.id, name: plan.name)
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The plans from the agent's status, in the menu's order.
struct PlanEntityQuery: EnumerableEntityQuery {
    @Dependency private var gateway: ShortcutGateway

    @MainActor func allEntities() async throws -> [PlanEntity] {
        await gateway.plans().map(PlanEntity.init)
    }

    /// A plan deleted since the shortcut was made still resolves, as "Deleted plan", so the action runs and says
    /// "That plan is no longer in Restorey." rather than failing before it starts with the system's own error.
    @MainActor func entities(for identifiers: [UUID]) async throws -> [PlanEntity] {
        let plans = await gateway.plans()
        return identifiers.map { id in
            plans.first { $0.id == id }.map(PlanEntity.init) ?? PlanEntity(id: id, name: "Deleted plan")
        }
    }

    @MainActor func suggestedEntities() async throws -> [PlanEntity] {
        try await allEntities()
    }
}

struct BackUpNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Back Up Now"
    static let description = IntentDescription(
        "Starts a backup, as Back Up Now in Restorey’s menu does. With no plan chosen, every plan backs up.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Plan", description: "The plan to back up. Leave it empty to back up every plan.")
    var plan: PlanEntity?

    @Dependency private var gateway: ShortcutGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Back up \(\.$plan) now")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let ready = try await gateway.ready()
        let call = try ShortcutRules.backUp(
            planID: plan?.id, health: ready.health, content: ready.content, status: ready.status
        ).get(orThrow: ShortcutError.init)
        switch await ready.connection.backUpNow(plan?.id) {
        case .success(let reply) where reply.alreadyRunning:
            return .result(dialog: "\(ShortcutRules.alreadyBackingUp(planName: plan?.name))")
        case .success:
            return .result(dialog: "\(call.dialog)")
        case .failure(let error):
            throw ShortcutError(error.description)
        }
    }
}

/// How long Pause Backups pauses for: `PauseLength`, with the menu's titles.
enum PauseLengthOption: String, AppEnum {
    case oneHour, fourHours, oneDay

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Length"
    static let caseDisplayRepresentations: [PauseLengthOption: DisplayRepresentation] = [
        .oneHour: DisplayRepresentation(title: "For 1 Hour"),
        .fourHours: DisplayRepresentation(title: "For 4 Hours"),
        .oneDay: DisplayRepresentation(title: "Until Tomorrow"),
    ]

    var length: PauseLength {
        switch self {
        case .oneHour: .oneHour
        case .fourHours: .fourHours
        case .oneDay: .oneDay
        }
    }
}

struct PauseBackupsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Backups"
    static let description = IntentDescription(
        "Stops a backup in progress and holds off backups for an hour, 4 hours or until tomorrow, as Pause in Restorey’s menu does. They resume by themselves. With no plan chosen, every backup in progress is paused; with nothing backing up, there’s nothing to pause.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Plan", description: "The plan to pause. Leave it empty to pause every backup in progress.")
    var plan: PlanEntity?

    @Parameter(title: "Length", description: "How long to pause for.", default: .oneHour)
    var length: PauseLengthOption

    @Dependency private var gateway: ShortcutGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Pause \(\.$plan) \(\.$length)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let ready = try await gateway.ready()
        let call = try ShortcutRules.pause(
            planID: plan?.id, length: length.length, health: ready.health, content: ready.content, status: ready.status
        ).get(orThrow: ShortcutError.init)
        guard case .pause(let plans) = call.kind else { return .result(dialog: "\(call.dialog)") }
        try await perPlan(.pause, plans, ready) { await ready.connection.pause($0, for: length.length) }
        return .result(dialog: "\(call.dialog)")
    }
}

struct CancelBackupIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Backup"
    static let description = IntentDescription(
        "Stops a backup in progress, as Cancel Backup in Restorey’s menu does. The schedule carries on. With no plan chosen, every backup in progress is cancelled.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Plan", description: "The plan whose backup to cancel. Leave it empty to cancel every backup in progress.")
    var plan: PlanEntity?

    @Dependency private var gateway: ShortcutGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Cancel the backup of \(\.$plan)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let ready = try await gateway.ready()
        let call = try ShortcutRules.cancel(
            planID: plan?.id, health: ready.health, content: ready.content, status: ready.status
        ).get(orThrow: ShortcutError.init)
        guard case .cancel(let plans) = call.kind else { return .result(dialog: "\(call.dialog)") }
        let results = try await perPlan(.cancel, plans, ready, ready.connection.cancel)
        return .result(dialog: "\(ShortcutRules.cancelDialog(call, results: results.map { ($0.name, $0.value.outcome) }))")
    }
}

struct ResumeBackupsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Backups"
    static let description = IntentDescription(
        "Resumes paused backups and starts one at once, as Resume in Restorey’s menu does. With no plan chosen, every paused plan resumes.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Plan", description: "The plan to resume. Leave it empty to resume every paused plan.")
    var plan: PlanEntity?

    @Dependency private var gateway: ShortcutGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$plan)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let ready = try await gateway.ready()
        let call = try ShortcutRules.resume(
            planID: plan?.id, health: ready.health, content: ready.content, status: ready.status
        ).get(orThrow: ShortcutError.init)
        guard case .resume(let plans) = call.kind else { return .result(dialog: "\(call.dialog)") }
        try await perPlan(.resume, plans, ready, ready.connection.resume)
        return .result(dialog: "\(call.dialog)")
    }
}

/// The last backup's time and outcome as values a shortcut can use (an "If" on Backed Up, a notification with the
/// summary). Only reads: nothing changes.
struct LastBackupEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Last Backup"

    @Property(title: "Plan") var plan: String
    @Property(title: "Time") var time: Date?
    @Property(title: "Outcome") var outcome: String
    @Property(title: "Backed Up") var savedData: Bool
    @Property(title: "Last Successful Backup") var lastSuccessfulBackup: Date?
    @Property(title: "Summary") var summary: String

    init() {
        plan = ""
        outcome = ""
        savedData = false
        summary = ""
    }

    init(_ report: LastBackupReport) {
        self.init()
        plan = report.planName
        time = report.endedAt
        outcome = report.outcome
        savedData = report.savedData
        lastSuccessfulBackup = report.lastSavedAt
        summary = report.summary
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
}

struct GetLastBackupIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Backup"
    static let description = IntentDescription(
        "Gets when a plan last backed up and how it went. With no plan chosen, the newest backup of any plan.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Plan", description: "The plan to ask about. Leave it empty for the newest backup of any plan.")
    var plan: PlanEntity?

    @Dependency private var gateway: ShortcutGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Get the last backup of \(\.$plan)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<LastBackupEntity> & ProvidesDialog {
        let ready = try await gateway.ready()
        let report = try ShortcutRules.lastBackup(
            planID: plan?.id, health: ready.health, content: ready.content, status: ready.status,
            now: Date(), calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent
        ).get(orThrow: ShortcutError.init)
        return .result(value: LastBackupEntity(report), dialog: "\(report.summary)")
    }
}

/// The actions the Shortcuts app and Spotlight offer with no setting up. Every phrase names the app (App Intents
/// requires it); the phrases are what the system matches where it supports App Shortcuts phrases.
struct RestoreyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BackUpNowIntent(),
            phrases: [
                "Back up with \(.applicationName)",
                "Back up now with \(.applicationName)",
                "Back up \(\.$plan) with \(.applicationName)",
            ],
            shortTitle: "Back Up Now", systemImageName: "arrow.up.circle")
        AppShortcut(
            intent: PauseBackupsIntent(),
            phrases: ["Pause \(.applicationName)", "Pause backups in \(.applicationName)"],
            shortTitle: "Pause Backups", systemImageName: "pause.circle")
        AppShortcut(
            intent: CancelBackupIntent(),
            phrases: ["Cancel \(.applicationName) backup", "Cancel backup in \(.applicationName)"],
            shortTitle: "Cancel Backup", systemImageName: "xmark.circle")
        AppShortcut(
            intent: ResumeBackupsIntent(),
            phrases: ["Resume \(.applicationName)", "Resume backups in \(.applicationName)"],
            shortTitle: "Resume Backups", systemImageName: "play.circle")
        AppShortcut(
            intent: GetLastBackupIntent(),
            phrases: [
                "When did \(.applicationName) last back up",
                "Get last backup from \(.applicationName)",
                "Get last backup of \(\.$plan) from \(.applicationName)",
            ],
            shortTitle: "Get Last Backup", systemImageName: "clock.arrow.circlepath")
    }
}

/// Makes the menu's per-plan call for each plan, every one whatever the earlier ones did (as the menu's "All Plans"
/// does), then throws one error naming each plan that failed and those that changed (`ShortcutRules.failureMessage`).
/// Returns each plan's name and the call's reply, for the calls that answered.
@MainActor @discardableResult
private func perPlan<Reply>(
    _ action: ShortcutRules.PerPlanAction, _ plans: [UUID], _ ready: ShortcutGateway.Ready,
    _ call: (UUID) async -> Result<Reply, AgentCallError>
) async throws -> [(name: String, value: Reply)] {
    var outcomes: [ShortcutRules.PlanOutcome] = []
    var replies: [(name: String, value: Reply)] = []
    for id in plans {
        let name = ready.content.actions.plans.first { $0.id == id }?.name ?? "Deleted plan"
        switch await call(id) {
        case .failure(let error):
            outcomes.append(.init(planName: name, failure: error.description))
        case .success(let reply):
            outcomes.append(.init(planName: name, failure: nil))
            replies.append((name, reply))
        }
    }
    if let message = ShortcutRules.failureMessage(action, outcomes: outcomes) { throw ShortcutError(message) }
    return replies
}

private extension Result where Failure == ShortcutRefusal {
    /// The value, or the refusal as the error Shortcuts shows.
    func get(orThrow wrap: (ShortcutRefusal) -> ShortcutError) throws -> Success {
        switch self {
        case .success(let value): value
        case .failure(let refusal): throw wrap(refusal)
        }
    }
}
