import Foundation
import Observation
import RestoreyCore

/// One opening of the Restore Files window (UI design §5, v0.1): a plan's restic restore commands
/// (`RestoreCommands`), masked. "Show Passwords and Keys" keeps them shown until hidden, the window stops being key
/// or closes; holding Option shows them while held (`SecretReveal`). The copy buttons copy the real command.
/// The first reveal or copy of a secret asks for Touch ID or the login password, once per opening, and only then
/// are the plan's secrets fetched (the agent's `recoveryKit`). They are held for the plan shown and go when
/// another plan is picked and when the window closes (`close`).
@MainActor
@Observable
final class RestoreFilesModel {
    var planID: UUID {
        didSet { if planID != oldValue { dropSecrets() } }
    }
    /// What shows: the button's kept reveal and Option's peek.
    private(set) var reveal = SecretReveal()
    private(set) var working = false
    private(set) var problem: String?
    private(set) var copied: String?

    /// The owner was confirmed in this opening: the button no longer asks.
    private(set) var authenticated = false
    /// The owner declined (or the Mac couldn't ask) in this opening: Option no longer prompts by itself.
    private(set) var declined = false
    @ObservationIgnored private var secrets: RecoveryKitSecrets?
    /// The opening: bumped by `dropSecrets` (the plan changed or the window closed). Taken before a prompt and checked
    /// before and after the fetch, so a closed opening never asks the agent and a late answer is thrown away.
    @ObservationIgnored private var generation = 0
    /// Observed copy of whether the secrets for the plan shown are here.
    private(set) var hasSecrets = false
    @ObservationIgnored private let supervisor: AgentSupervisor
    /// The window's key state, fed by `OptionKeyMonitor`, for the reveal's wait.
    @ObservationIgnored private let keyWaiter = KeyWaiter()

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

    var revealed: Bool { reveal.visible && hasSecrets }

    /// Holding Option asks for the owner only until they decline once: after that, Option alone never brings
    /// the prompt back in this opening, and the button or a copy does.
    func optionChanged(_ held: Bool) {
        reveal.optionChanged(held)
        if held, !hasSecrets, !declined { Task { await fetchSecrets() } }
    }

    /// "Show Passwords and Keys(…)" / "Hide Passwords and Keys". Showing asks for the owner first if this opening
    /// hasn't yet; approving keeps them shown. After a prompt the window gets the key back only once macOS grants
    /// the activation `OwnerAuthentication` asks for, so the order is `RevealOrder`'s: ask, wait for the window to be
    /// back (up to `keyWait`), fetch, then show only if it is still key (fix round 3, N1). The opening is taken
    /// before the prompt, so a window closed (or a plan changed) during the prompt or the wait never fetches; `close`
    /// also ends the wait at once (fix round 4, I1).
    func revealButtonPressed() async {
        if reveal.kept {
            reveal.toggle()
            return
        }
        if hasSecrets {
            reveal.approvedByButton()
            return
        }
        guard !working else { return }
        working = true
        defer { working = false }
        let opening = generation
        let show = await RevealOrder.reveal(
            waiter: keyWaiter, prompts: !authenticated, timeout: Self.keyWait,
            isCurrent: { opening == self.generation },
            approve: { await self.authenticate(opening) },
            fetch: { await self.fetchFromAgent(opening) })
        if show { reveal.approvedByButton() }
    }

    /// How long a reveal waits for the window to be key again after the prompt.
    static let keyWait: Duration = .seconds(1)

    func resignedKey() {
        reveal.resignedKey()
        keyWaiter.resignedKey()
    }

    func becameKey() {
        reveal.becameKey()
        keyWaiter.becameKey()
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
        guard !working else { return false }
        working = true
        defer { working = false }
        let opening = generation
        guard await authenticate(opening) else { return false }
        return await fetchFromAgent(opening)
    }

    /// Asks for the owner if this opening hasn't yet. True once confirmed, while `opening` is still the one shown.
    private func authenticate(_ opening: Int) async -> Bool {
        guard opening == generation, let plan else { return false }
        problem = nil
        if !authenticated {
            let outcome = await OwnerAuthentication.confirm(
                reason: "show the restore commands for “\(plan.name)”", returningTo: .restoreFiles)
            // The window closed or another plan was picked while macOS asked: the answer, whichever it was, was for
            // that opening, so nothing of it (`declined`, `problem`) is kept for this one.
            guard opening == generation else { return false }
            switch outcome {
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
            authenticated = true
        }
        return true
    }

    /// Fetches the plan's secrets from the agent (the owner already confirmed), only while `opening` is still the
    /// one shown: a closed window or a changed plan asks for nothing, and an answer that comes after is dropped.
    private func fetchFromAgent(_ opening: Int) async -> Bool {
        guard opening == generation else { return false }
        if hasSecrets { return true }
        guard let plan else { return false }
        switch await supervisor.connection.recoveryKit(plan.id) {
        case .success(let reply):
            guard opening == generation, reply.plan.id == planID else { return false }
            secrets = reply
            hasSecrets = true
            return true
        case .failure(let error):
            guard opening == generation else { return false }
            problem = FormValidation.sentence(error.description)
            return false
        }
    }

    /// Ends the opening: secrets go, and a reveal waiting for the window stops waiting (`KeyWaiter.cancel`).
    private func dropSecrets() {
        generation += 1
        keyWaiter.cancel()
        secrets = nil
        hasSecrets = false
        problem = nil
        reveal.reset()
    }

    func close() {
        dropSecrets()
        authenticated = false
        declined = false
        reveal.reset()
    }
}
