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

    /// Asks for Touch ID or the password, then fetches the kit. Only for a plan that finished setup.
    ///
    /// `revealing`: asked for by the button after a decline, so approving shows the passwords and keys at once
    /// (owner ruling, 13 Nov); the prompt made on opening shows the kit with them as dots.
    func unlock(revealing: Bool = false) async {
        guard let plan, plan.setupState != .unfinished, gate != .asking, gate != .open else { return }
        gate = .asking
        switch await OwnerAuthentication.confirm(
            reason: "show the recovery kit for “\(plan.plan.name)”", returningTo: .recoveryKit) {
        case .confirmed: break
        case .declined:
            gate = .declined
            return
        case .unavailable(let sentence):
            gate = .unavailable(sentence)
            return
        }
        // The window may have closed while macOS asked.
        guard gate == .asking else { return }
        gate = .open
        await kit.load()
        if revealing, kit.document != nil { kit.revealByButton() }
    }

    /// "I've saved it somewhere other than this Mac": the agent's `confirmRecoveryKit`, which lets backups carry on.
    /// Checked first against the agent's current secrets, so a kit holding keys changed since it opened is
    /// replaced and shown again rather than confirmed.
    func confirmSaved() async {
        guard gate == .open, kit.document != nil, !confirming else { return }
        confirming = true
        confirmProblem = nil
        replacedBeforeConfirming = false
        defer { confirming = false }
        switch await kit.stillCurrent() {
        case false?:
            replacedBeforeConfirming = true
            return
        case nil:
            confirmProblem = "Restorey couldn't check the kit against the plan's keys. Try again."
            return
        case true?:
            break
        }
        switch await supervisor.connection.confirmRecoveryKit(planID) {
        case .success: confirmedHere = true
        case .failure(let error): confirmProblem = FormValidation.sentence(error.description)
        }
    }

    func close() {
        gate = .locked
        kit.close()
    }
}

struct RecoveryKitWindow: View {
    let model: RecoveryKitWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.heading).font(.title3.weight(.semibold))
            content
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .frame(minHeight: 260, alignment: .topLeading)
        // Again when the first status arrives: before it, the plan (and whether it finished setup) is unknown.
        .task(id: model.plan != nil) { await model.unlock() }
    }

    @ViewBuilder private var content: some View {
        if let plan = model.plan {
            if plan.setupState == .unfinished {
                Text("Setup for “\(plan.plan.name)” isn't finished, so it has no recovery kit yet. Finishing setup shows it.")
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
                Text("Waiting for Restorey's background agent…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func gated(_ plan: PlanStatus) -> some View {
        switch model.gate {
        case .locked, .asking:
            Text("Restorey asks for Touch ID or your login password before showing the kit, because it holds the keys to your backups.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .declined, .unavailable:
            if case .unavailable(let sentence) = model.gate {
                Label(sentence, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
            RecoveryKitView(model: model.kit)
            Text(RecoveryKitText.keepItSafe)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if plan.setupState == .needsNewKit || model.confirmedHere {
                confirmation
            }
        }
    }

    @ViewBuilder private var confirmation: some View {
        if model.confirmedHere {
            Label("Saved. Backups carry on.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else {
            Toggle(RecoveryKitText.savedTick, isOn: Binding(
                get: { model.confirming },
                set: { if $0 { Task { await model.confirmSaved() } } }))
                .toggleStyle(.checkbox)
                .disabled(model.kit.document == nil || model.confirming)
            if model.replacedBeforeConfirming {
                Label("The plan's keys changed while this kit was open. This is the new kit: save it, then tick again.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.confirmProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
