import Foundation

/// The steps of the setup window, in the owner's order: permissions first, then the storage, then the
/// password and recovery kit right after the endpoint, then what to back up, when, and the first backup.
public enum SetupStep: String, Codable, Sendable, CaseIterable {
    case moveToApplications
    case permissions
    case storage
    case password
    case recoveryKit
    case sources
    case schedule
    /// The first backup has run; nothing is left to do.
    case done
}

/// Where an interrupted setup was left, saved so quitting the window (or the app) can resume it.
/// `addingPlan` is true for "+ Add plan…", which starts at `.storage` and never repeats the permissions.
public struct SetupProgress: Codable, Sendable, Equatable {
    /// Nil until "Check" has saved the plan (Ruling P2-2), and on a first run before that.
    public var planID: UUID?
    public var step: SetupStep
    public var addingPlan: Bool
    /// The recovery kit has been saved or printed at `.recoveryKit`. The agent's confirmation is deferred
    /// to Done (see `SetupFlow`), so this, not the plan, is what lets setup go past `.recoveryKit`.
    public var kitSaved: Bool
    /// The permissions step's "Open at login" choice, kept from the moment it is switched until Continue applies
    /// it, because granting Full Disk Access quits the app mid-step. Nil until switched: on (P2-16).
    public var openAtLogin: Bool?
    /// This setup ran "Create New Repository" for the plan's address and it succeeded. Only that says the
    /// repository is this setup's own: a password that opens it may just have been typed for someone else's.
    public var repositoryCreated: Bool
    /// What adopting the repository reported (hosts, the latest snapshot's paths for the host label, the count),
    /// kept for the sources step's new-group warning after a quit. Set only once `adopt` has succeeded. Host names
    /// and folder paths, no secret.
    public var adoption: AdoptReport?

    public init(
        planID: UUID?, step: SetupStep, addingPlan: Bool, kitSaved: Bool = false, openAtLogin: Bool? = nil,
        repositoryCreated: Bool = false, adoption: AdoptReport? = nil
    ) {
        self.planID = planID
        self.step = step
        self.addingPlan = addingPlan
        self.kitSaved = kitSaved
        self.openAtLogin = openAtLogin
        self.repositoryCreated = repositoryCreated
        self.adoption = adoption
    }

    private enum CodingKeys: String, CodingKey {
        case planID, step, addingPlan, kitSaved, openAtLogin, repositoryCreated, adoption
    }

    /// Progress stored before `kitSaved`, `openAtLogin`, `repositoryCreated` or `adoption` existed still decodes:
    /// not saved, not switched, nothing created or adopted.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planID = try c.decodeIfPresent(UUID.self, forKey: .planID)
        step = try c.decode(SetupStep.self, forKey: .step)
        addingPlan = try c.decode(Bool.self, forKey: .addingPlan)
        kitSaved = try c.decodeIfPresent(Bool.self, forKey: .kitSaved) ?? false
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin)
        repositoryCreated = try c.decodeIfPresent(Bool.self, forKey: .repositoryCreated) ?? false
        adoption = try c.decodeIfPresent(AdoptReport.self, forKey: .adoption)
    }
}

/// What the password step shows, from what is known about the plan's address (UI design §4 step 3).
public enum PasswordStep: Sendable, Equatable {
    /// Nothing known yet: a resumed step probes again.
    case probing
    /// A resumed step's probe failed (the step shows why): "Try Again" probes again.
    case probeFailed
    /// Nothing there: a password and "Create New Repository".
    case create
    /// A repository the saved password doesn't open: ask for its own.
    case open
    /// A repository the saved password opens, not made by this setup: choose the host label and adopt it.
    case adopt(AdoptReport)
    /// Created, or adopted, by this setup: Continue.
    case ready

    /// Decided from the recorded facts first (`repositoryCreated`, `adoption`), never from the plan's origin:
    /// a plan saved with a typed password that opens someone else's repository still has its new-plan origin.
    /// `probeFailed`: the last probe of the address failed, so nothing is known and the step shouldn't sit on a
    /// spinner.
    public static func decide(
        probe: RepositoryProbe.State?, progress: SetupProgress, probeFailed: Bool = false
    ) -> PasswordStep {
        if progress.repositoryCreated || progress.adoption != nil { return .ready }
        switch probe {
        case nil: return probeFailed ? .probeFailed : .probing
        case .empty?: return .create
        case .passwordRejected?: return .open
        case .existing(let report)?: return .adopt(report)
        }
    }
}

/// What the window currently knows, for deciding whether Continue is allowed.
public struct SetupFacts: Sendable, Equatable {
    /// The app is in /Applications.
    public var installed: Bool
    /// Full Disk Access is granted. Notifications are optional, so they are not a fact here.
    public var fdaGranted: Bool
    /// The result of the storage step's "Check", once it has run.
    public var probe: RepositoryProbe?
    /// The repository exists and the password opens it: created, or adopted with the password accepted.
    public var repositoryReady: Bool
    /// Gates leaving `.recoveryKit`. During setup it reflects `SetupProgress.kitSaved` (the kit has been
    /// saved or printed), not the agent's confirmation, which only happens at Done.
    public var kitConfirmed: Bool

    public init(installed: Bool, fdaGranted: Bool, probe: RepositoryProbe?, repositoryReady: Bool, kitConfirmed: Bool) {
        self.installed = installed
        self.fdaGranted = fdaGranted
        self.probe = probe
        self.repositoryReady = repositoryReady
        self.kitConfirmed = kitConfirmed
    }
}

/// The setup step machine the setup window drives.
///
/// Ordering that the window must keep: the recovery kit is saved at `.recoveryKit` (recorded as
/// `SetupProgress.kitSaved`), but the agent's `confirmRecoveryKit` is deferred. Confirming makes the plan
/// `.complete` and runnable, and sources and schedule come after the kit, so confirming early would let the
/// scheduler back up the default sources mid-setup. On Done ("Start first backup") the window calls
/// `confirmRecoveryKit` and then `backUpNow`. Until then the plan stays `.unfinished`, which is what lets
/// `resume` bring the owner back to sources, schedule or done.
public enum SetupFlow {
    public static func firstStep(installed: Bool, addingPlan: Bool) -> SetupStep {
        if addingPlan { return .storage }
        return installed ? .permissions : .moveToApplications
    }

    public static func canContinue(from step: SetupStep, facts: SetupFacts) -> Bool {
        switch step {
        case .moveToApplications: facts.installed
        case .permissions: facts.fdaGranted
        case .storage: facts.probe != nil
        case .password: facts.repositoryReady
        case .recoveryKit: facts.kitConfirmed
        // Their form controls validate as the owner edits, so Continue is always allowed.
        case .sources, .schedule: true
        case .done: false
        }
    }

    /// Callers check `canContinue` first. `facts` is unused because the order is fixed.
    public static func next(after step: SetupStep, facts: SetupFacts) -> SetupStep {
        switch step {
        case .moveToApplications: .permissions
        case .permissions: .storage
        case .storage: .password
        case .password: .recoveryKit
        case .recoveryKit: .sources
        case .sources: .schedule
        case .schedule, .done: .done
        }
    }

    /// Where to pick setup up when the app starts, or nil when there is nothing to resume.
    ///
    /// Only `.unfinished` plans count. A `.needsNewKit` plan finished setup once and is the recovery-kit
    /// window's job, so it is treated like `.complete` here. Saved progress for a plan that no longer
    /// exists, or is no longer unfinished, is discarded. With several unfinished plans the saved one wins,
    /// otherwise the first in `plans`. "+ Add plan…" progress resumes as adding a plan, at its saved step.
    /// A saved step past `.recoveryKit` needs `kitSaved`, otherwise it resumes at `.recoveryKit`. `.done` is
    /// valid while the plan is unfinished: "Start first backup" hasn't been pressed yet.
    public static func resume(saved: SetupProgress?, plans: [PlanStatus], installed: Bool) -> SetupProgress? {
        let unfinished = plans.filter { $0.setupState == .unfinished }
        if let saved, isStillValid(saved, plans: plans, unfinished: unfinished) {
            return reconciled(saved, installed: installed)
        }
        if plans.isEmpty {
            return SetupProgress(planID: nil, step: firstStep(installed: installed, addingPlan: false), addingPlan: false)
        }
        guard let first = unfinished.first else { return nil }
        return reconciled(SetupProgress(planID: first.plan.id, step: .storage, addingPlan: false), installed: installed)
    }

    /// Where a setup window opened by hand (the menu's "Finish setup…") starts. `plans` nil means the agent hasn't
    /// sent a status yet: the plans are unknown, so the saved progress is kept (only reconciled with the install
    /// location) rather than discarded as stale. With nothing to resume it starts at the first step.
    public static func opening(saved: SetupProgress?, plans: [PlanStatus]?, installed: Bool) -> SetupProgress {
        let first = SetupProgress(planID: nil, step: firstStep(installed: installed, addingPlan: false), addingPlan: false)
        guard let plans else { return saved.map { reconciled($0, installed: installed) } ?? first }
        return resume(saved: saved, plans: plans, installed: installed) ?? first
    }

    /// What "+ Add plan…" in Settings opens. Setup keeps one saved progress, so a setup still to finish is carried
    /// on rather than overwritten: an unfinished plan's is finished first (the caller says so and offers it), and
    /// one with no plan saved yet (an add before "Check", or a first run with no plans) simply reopens. Otherwise a
    /// new add starts at `.storage`.
    public static func addingPlan(saved: SetupProgress?, plans: [PlanStatus], installed: Bool) -> AddPlanStart {
        guard let pending = resume(saved: saved, plans: plans, installed: installed) else {
            return .start(SetupProgress(planID: nil, step: firstStep(installed: installed, addingPlan: true), addingPlan: true))
        }
        guard let planID = pending.planID else { return .resume(pending) }
        let name = plans.first { $0.plan.id == planID }?.plan.name ?? ""
        return .finishFirst(pending, planName: name)
    }

    private static func isStillValid(_ saved: SetupProgress, plans: [PlanStatus], unfinished: [PlanStatus]) -> Bool {
        guard let planID = saved.planID else {
            // Before "Check" saved a plan: an added plan's draft, or a first run with no plans yet.
            return saved.addingPlan || plans.isEmpty
        }
        return unfinished.contains { $0.plan.id == planID }
    }

    /// The app may have been moved in or out of /Applications since the progress was saved.
    private static func reconciled(_ progress: SetupProgress, installed: Bool) -> SetupProgress {
        var progress = progress
        if let index = SetupStep.allCases.firstIndex(of: progress.step),
            index > SetupStep.allCases.firstIndex(of: .recoveryKit)!, !progress.kitSaved
        {
            progress.step = .recoveryKit
        }
        guard !progress.addingPlan else { return progress }
        if !installed {
            progress.step = .moveToApplications
        } else if progress.step == .moveToApplications {
            progress.step = .permissions
        }
        return progress
    }
}

/// `SetupFlow.addingPlan`'s answer.
public enum AddPlanStart: Sendable, Equatable {
    /// A new add, from "Where backups go".
    case start(SetupProgress)
    /// A setup with no plan saved yet: reopen it as it is.
    case resume(SetupProgress)
    /// `planName`'s setup isn't finished: finish it (at this progress) before adding another.
    case finishFirst(SetupProgress, planName: String)
}

/// `SetupProgress` in `UserDefaults` (key `setupProgress`). The defaults are injected so tests never touch
/// the app's own. It holds no secrets: the step, the plan's id and the facts above (folder paths and host names).
public struct SetupProgressStore {
    public static let key = "setupProgress"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Corrupt or unreadable data is nil, never a crash.
    public func load() -> SetupProgress? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SetupProgress.self, from: data)
    }

    public func save(_ progress: SetupProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
