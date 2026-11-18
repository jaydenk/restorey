import AppIntents
import Observation
import RestoreyCore

/// What Restorey's Shortcuts actions (Task 17e, audit T2) reach the agent through: the same supervisor, XPC connection and
/// menu content the status item uses, so an action is refused exactly when the menu's item would be (`ShortcutRules`).
/// The actions run in this process (they are in the app's bundle, with no App Intents extension: only the app may talk
/// to the agent), so Shortcuts launches Restorey in the background to run one when it isn't already running.
///
/// Made in `AppDelegate.main` and handed to App Intents (`AppDependencyManager`) before the app runs, so it is there
/// for an action that launched the app; `AppDelegate.setUp` then says what this copy is.
@MainActor
@Observable
final class ShortcutGateway {
    enum Copy {
        /// The copy in /Applications, which runs the agent.
        case installed(AgentSupervisor)
        /// A copy that may not touch the agent (`InstallVerdict` other than `.ok`), or a broken build.
        case refused(String)
    }

    /// Nil until launch has decided.
    var copy: Copy?

    /// What an action acts on: the agent's state as the menu has it now.
    struct Ready {
        let connection: AgentConnection
        let health: AgentHealthState
        let status: AgentStatus?
        let content: MenuContent
    }

    /// Waits (up to `ShortcutRules.settleTimeout`) while Restorey is still connecting to the agent, as it is when the
    /// action launched it, then reads the state. Throws for a copy that can't touch the agent.
    func ready() async throws -> Ready {
        if !isSettled { await waitUntilSettled() }
        switch copy {
        case .installed(let supervisor):
            let status = menuStatus(health: supervisor.health, live: supervisor.status, lastKnown: supervisor.lastKnownStatus)
            let content = MenuPresentation.make(
                health: supervisor.health, status: status,
                notificationsAuthorised: supervisor.lastHello?.notificationsAuthorised,
                now: Date(), calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
            return Ready(connection: supervisor.connection, health: supervisor.health, status: status, content: content)
        case .refused(let sentence):
            throw ShortcutError(sentence)
        case nil:
            throw ShortcutError("Restorey didn’t finish opening in time.")
        }
    }

    /// The plans Shortcuts lists, from the menu's status.
    func plans() async -> [ShortcutPlan] {
        guard let ready = try? await ready() else { return [] }
        return ShortcutRules.plans(ready.status)
    }

    private var isSettled: Bool {
        switch copy {
        case nil: false
        case .refused: true
        case .installed(let supervisor):
            ShortcutRules.isSettled(health: supervisor.health, hasStatus: supervisor.status != nil)
        }
    }

    /// Until `isSettled` (observed, so no polling) or the timeout, whichever comes first.
    private func waitUntilSettled() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.settles() }
            group.addTask {
                try? await Task.sleep(for: ShortcutRules.settleTimeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Returns once `isSettled` is true, observing the supervisor's health and status as they change.
    private func settles() async {
        let changes = Observations { self.isSettled }
        for await settled in changes where settled { return }
    }

    // MARK: Plan names for Siri

    @ObservationIgnored private var lastPlanNames: [String]?

    /// The plans' names go into the App Shortcuts' phrases ("Back up Home with Restorey"): App Intents is told when they
    /// change (`updateAppShortcutParameters`).
    func statusChanged(_ status: AgentStatus?) {
        let names = ShortcutRules.plans(status).map(\.name)
        guard status != nil, names != lastPlanNames else { return }
        lastPlanNames = names
        RestoreyShortcuts.updateAppShortcutParameters()
    }
}

/// An action's error, in words Shortcuts shows: App Intents shows `localizedStringResource`, not `LocalizedError`'s
/// description, so a plain error would read as a generic failure.
struct ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(_ refusal: ShortcutRefusal) {
        message = refusal.message
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
