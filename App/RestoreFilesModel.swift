import Foundation
import Observation
import RestoreyCore

/// One opening of the Restore Files window (UI design §5, v0.1): a plan's restic restore commands
/// (`RestoreCommands`), masked. Holding Option reveals them while held; the copy buttons copy the real command.
/// The first reveal or copy of a secret asks for Touch ID or the login password, once per opening, and only then
/// are the plan's secrets fetched (the agent's `recoveryKit`). They are held for the plan shown and go when
/// another plan is picked and when the window closes (`close`).
@MainActor
@Observable
final class RestoreFilesModel {
    var planID: UUID {
        didSet { if planID != oldValue { dropSecrets() } }
    }
    /// Option is down and the window is key (`OptionKeyMonitor`).
    private(set) var optionHeld = false
    private(set) var working = false
    private(set) var problem: String?
    private(set) var copied: String?

    @ObservationIgnored private var authenticated = false
    /// The owner declined (or the Mac couldn't ask) in this opening: Option no longer prompts by itself.
    private(set) var declined = false
    @ObservationIgnored private var secrets: RecoveryKitSecrets?
    /// Bumped by `dropSecrets`, so a fetch that answers after the plan changed or the window closed is thrown away.
    @ObservationIgnored private var generation = 0
    /// Observed copy of whether the secrets for the plan shown are here.
    private(set) var hasSecrets = false
    @ObservationIgnored private let supervisor: AgentSupervisor

    init(planID: UUID, supervisor: AgentSupervisor) {
        self.planID = planID
        self.supervisor = supervisor
    }

    /// Every plan with commands to give: all but an unfinished one, which has no confirmed kit and may have no
    /// repository yet (as the menu's Restore Files… lists them).
    var plans: [Plan] {
        (supervisor.lastKnownStatus?.plans ?? []).filter { $0.setupState != .unfinished }.map(\.plan)
    }

    var plan: Plan? { plans.first { $0.id == planID } }
    var statusKnown: Bool { supervisor.lastKnownStatus != nil }

    var commands: [RestoreCommands.Command] {
        guard let plan else { return [] }
        return RestoreCommands.make(plan: plan, secrets: hasSecrets ? secrets?.secrets ?? [] : [])
    }

    var revealed: Bool { optionHeld && hasSecrets }

    /// Holding Option asks for the owner only until they decline once: after that, Option alone never brings
    /// the prompt back in this opening, and "Show Passwords and Keys…" (`askAgain`) or a copy does.
    func optionChanged(_ held: Bool) {
        optionHeld = held
        if held, !hasSecrets, !declined { Task { await fetchSecrets() } }
    }

    /// The explicit way to ask again after a decline.
    func askAgain() async {
        await fetchSecrets()
    }

    /// Copies the real command, by title, so the caller's copy (which may be the revealed one) isn't held here.
    func copy(_ title: String) async {
        guard let command = commands.first(where: { $0.title == title }) else { return }
        if command.needsSecrets {
            guard await fetchSecrets(), let current = commands.first(where: { $0.title == title }) else { return }
            ConcealedPasteboard.copy(current.revealedText)
        } else {
            ConcealedPasteboard.copy(command.revealedText, concealed: false)
        }
        showCopied(title)
    }

    /// "Copied" for a moment; only the title is kept.
    private func showCopied(_ title: String) {
        copied = title
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.copied == title { self?.copied = nil }
        }
    }

    /// Whether the plan's secrets are here, asking for the owner first if this opening hasn't yet.
    @discardableResult
    private func fetchSecrets() async -> Bool {
        if hasSecrets { return true }
        guard !working, let plan else { return false }
        working = true
        problem = nil
        defer { working = false }
        let asked = generation
        if !authenticated {
            switch await OwnerAuthentication.confirm(reason: "show the restore commands for “\(plan.name)”") {
            case .confirmed:
                declined = false
            case .declined:
                declined = true
                problem = "The passwords and keys stay hidden until you use Touch ID or enter your login password."
                return false
            case .unavailable(let sentence):
                declined = true
                problem = sentence
                return false
            }
            guard asked == generation else { return false }
            authenticated = true
        }
        switch await supervisor.connection.recoveryKit(plan.id) {
        case .success(let reply):
            guard asked == generation, reply.plan.id == planID else { return false }
            secrets = reply
            hasSecrets = true
            return true
        case .failure(let error):
            guard asked == generation else { return false }
            problem = FormValidation.sentence(error.description)
            return false
        }
    }

    private func dropSecrets() {
        generation += 1
        secrets = nil
        hasSecrets = false
        problem = nil
    }

    func close() {
        dropSecrets()
        authenticated = false
        declined = false
        optionHeld = false
    }
}
