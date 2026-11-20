import Observation
import RestoreyCore
import SwiftUI

/// The recovery kit outside setup: "New recovery kit needed — Save Recovery Kit…" in the menu, and "Show recovery
/// kit…" in Settings (UI design §6.2, §7). Behind Touch ID or the login password (`OwnerAuthentication`), asked once
/// per opening; the secrets are fetched only after it succeeds and go when the window closes (`close`).
///
/// Only a plan that has finished setup is shown here. That is the agent's `PlanSetupState`: `setupCompletedAt` is
/// set by the plan's first `confirmRecoveryKit` (Done's "Start First Backup") and never cleared, so a plan past it
/// has its own repository password saved, never setup's stand-in. An unfinished plan is setup's job, and its kit
/// step's (which checks for the stand-in itself).
@MainActor
@Observable
final class RecoveryKitWindowModel {
    enum Gate: Equatable {
        case locked
        case asking
        /// Cancelled or failed: "Show Recovery Kit" asks again.
        case declined
        /// This Mac can't ask (no login password, say): the sentence says why.
        case unavailable(String)
        case open
    }

    let planID: UUID
    let kit: RecoveryKitModel
    private(set) var gate: Gate = .locked
    private(set) var confirming = false
    private(set) var confirmProblem: String?
    /// The kit shown was confirmed in this window.
    private(set) var confirmedHere = false
    /// The kit changed under the window (keys saved elsewhere) when it was about to be confirmed.
    private(set) var replacedBeforeConfirming = false

    /// Set by `close`. Each opening of the window has its own model, so a closed one never opens again.
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let supervisor: AgentSupervisor
    @ObservationIgnored let finishSetup: () -> Void

    init(planID: UUID, supervisor: AgentSupervisor, finishSetup: @escaping () -> Void) {
        self.planID = planID
        self.supervisor = supervisor
        self.finishSetup = finishSetup
        kit = RecoveryKitModel(planID: planID, connection: supervisor.connection)
    }

    /// The plan as the agent last reported it; nil before the first status, or once it is deleted.
    var plan: PlanStatus? { supervisor.lastKnownStatus?.plans.first { $0.plan.id == planID } }
    var statusKnown: Bool { supervisor.lastKnownStatus != nil }

    var heading: String {
        guard let plan else { return "Recovery Kit" }
        return plan.setupState == .needsNewKit && !confirmedHere
            ? RecoveryKitText.reconfirmHeading : "Recovery kit for “\(plan.plan.name)”"
    }

    /// Asks for Touch ID or the password, then fetches the kit. Only for a plan that finished setup, and only while
    /// the window is open: a window closed during the prompt or the wait after it never fetches (fix round 4, I1).
    ///
    /// `revealing`: asked for by the button after a decline, so approving shows the passwords and keys at once
    /// (owner ruling, 13 Nov); the prompt made on opening shows the kit with them as dots.
    func unlock(revealing: Bool = false) async {
        guard !closed, let plan, plan.setupState != .unfinished, gate != .asking, gate != .open else { return }
        gate = .asking
        let approve = { () async -> Bool in
            let outcome = await OwnerAuthentication.confirm(
                reason: "show the recovery kit for “\(plan.plan.name)”", returningTo: .recoveryKit)
            // The window may have closed while macOS asked: it stays locked.
            guard !self.closed, self.gate == .asking else { return false }
            switch outcome {
            case .confirmed:
                self.gate = .open
                return true
            case .declined:
                self.gate = .declined
            case .unavailable(let sentence):
                self.gate = .unavailable(sentence)
            }
            return false
        }
        let isOpen = { !self.closed && self.gate == .open }
        let load = { () async -> Bool in
            guard isOpen() else { return false }
            await self.kit.load()
            return self.kit.document != nil
        }
        guard revealing else {
            if await approve() { _ = await load() }
            return
        }
        // `RevealOrder` (fix rounds 3 and 4): the window is key again only once macOS gives the front back to Restorey
        // after the prompt, so wait for that, then load, then show only if it is still key and still open.
        let show = await RevealOrder.reveal(
            waiter: kit.keyWaiter, prompts: true, timeout: RestoreFilesModel.keyWait,
            isCurrent: isOpen, approve: approve, fetch: load)
        if show { kit.revealByButton() }
    }

    /// "I've saved it somewhere other than this Mac": the agent's `confirmRecoveryKit`, which lets backups carry on.
    /// Checked first against the agent's current secrets, so a kit holding keys changed since it opened is
    /// replaced and shown again rather than confirmed. The confirmation carries the shown kit's digest, so a change
    /// saved between that check and the agent's answer is refused too (Task 9), and the kit is checked again.
    func confirmSaved() async {
        guard gate == .open, let shown = kit.document?.digest, !confirming else { return }
        confirming = true
        confirmProblem = nil
        replacedBeforeConfirming = false
        defer { confirming = false }
        switch await kit.stillCurrent() {
        case false?:
            replacedBeforeConfirming = true
            return
        case nil:
            confirmProblem = "Restorey couldn’t check the kit against the plan’s keys. Try again."
            return
        case true?:
            break
        }
        switch await supervisor.connection.confirmRecoveryKit(planID, kitDigest: shown) {
        case .success: confirmedHere = true
        case .failure(.refused(RecoveryKitDocument.detailsChangedRefusal)):
            // Replaces the kit with the current one and says so, as a change found before confirming does.
            if await kit.stillCurrent() == false {
                replacedBeforeConfirming = true
            } else {
                confirmProblem = RecoveryKitDocument.detailsChangedRefusal
            }
        case .failure(let error): confirmProblem = FormValidation.sentence(error.description)
        }
    }

    /// The window closed: the secrets go, a reveal waiting for the window stops waiting, and nothing more is
    /// fetched for this opening (`unlock` checks it after every wait).
    func close() {
        closed = true
        gate = .locked
        kit.close()
    }
}

struct RecoveryKitWindow: View {
    let model: RecoveryKitWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.heading).pageTitle()
            content
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .frame(minHeight: 260, alignment: .topLeading)
        .background(OptionKeyMonitor(
            onChange: { model.kit.optionChanged($0) }, onResignKey: { model.kit.resignedKey() },
            onBecomeKey: { model.kit.becameKey() }))
        // Again when the first status arrives: before it, the plan (and whether it finished setup) is unknown.
        .task(id: model.plan != nil) { await model.unlock() }
    }

    @ViewBuilder private var content: some View {
        if let plan = model.plan {
            if plan.setupState == .unfinished {
                Text("Setup for “\(plan.plan.name)” isn’t finished, so it has no recovery kit yet. Finishing setup shows it.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Finish Setup…") { model.finishSetup() }.keyboardShortcut(.defaultAction)
                }
            } else {
                gated(plan)
            }
        } else if model.statusKnown {
            Text("This plan is no longer there.").foregroundStyle(.secondary)
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for Restorey’s background process…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func gated(_ plan: PlanStatus) -> some View {
        switch model.gate {
        case .locked, .asking:
            Text("Restorey asks for Touch ID or your login password before showing the kit, because it holds the keys to your backups.")
                .explanatoryNote()
        case .declined, .unavailable:
            if case .unavailable(let sentence) = model.gate {
                SeverityText(sentence)
            } else {
                Text("The recovery kit stays hidden until you use Touch ID or enter your login password.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Show Recovery Kit") { Task { await model.unlock(revealing: true) } }.keyboardShortcut(.defaultAction)
            }
        case .open:
            Text(RecoveryKitText.why).fixedSize(horizontal: false, vertical: true)
            RecoveryKitView(model: model.kit, watchesKeys: false)
            Text(RecoveryKitText.keepItSafe)
                .explanatoryNote()
            if plan.setupState == .needsNewKit || model.confirmedHere {
                confirmation
            }
        }
    }

    @ViewBuilder private var confirmation: some View {
        if model.confirmedHere {
            Label {
                Text("Saved. Backups carry on.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
            }
        } else {
            Toggle(RecoveryKitText.savedTick, isOn: Binding(
                get: { model.confirming },
                set: { if $0 { Task { await model.confirmSaved() } } }))
                .toggleStyle(.checkbox)
                .disabled(model.kit.document == nil || model.confirming)
            if model.replacedBeforeConfirming {
                SeverityText(
                    "The plan’s keys changed while this kit was open. This is the new kit: save it, then tick again.",
                    severity: .warning)
            }
            if let problem = model.confirmProblem {
                SeverityText(problem)
            }
        }
    }
}
