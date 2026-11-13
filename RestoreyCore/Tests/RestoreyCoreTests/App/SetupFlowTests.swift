import Foundation
import Testing

@testable import RestoreyCore

@Suite struct SetupFlowTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func facts(
        installed: Bool = true, fda: Bool = false, probe: RepositoryProbe? = nil, ready: Bool = false, kit: Bool = false
    ) -> SetupFacts {
        SetupFacts(installed: installed, fdaGranted: fda, probe: probe, repositoryReady: ready, kitConfirmed: kit)
    }

    private static func status(_ name: String, _ state: PlanSetupState) -> PlanStatus {
        let plan = Plan.newHotPlan(
            name: name,
            repository: .s3(S3Location(
                provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!,
                bucket: "my-backups", prefix: name)),
            origin: .created, hostLabel: "mac", sources: ["/Users/me"], exclusions: [], now: now)
        return PlanStatus(plan: plan, phase: .idle, lastRecord: nil, nextRunAt: nil, alerts: [], setupState: state)
    }

    // MARK: First step

    @Test func notInstalledStartsWithMoveToApplications() {
        #expect(SetupFlow.firstStep(installed: false, addingPlan: false) == .moveToApplications)
    }

    @Test func installedStartsWithPermissions() {
        #expect(SetupFlow.firstStep(installed: true, addingPlan: false) == .permissions)
    }

    @Test func addingAPlanStartsAtStorage() {
        #expect(SetupFlow.firstStep(installed: true, addingPlan: true) == .storage)
        #expect(SetupFlow.firstStep(installed: false, addingPlan: true) == .storage)
    }

    // MARK: Continue

    @Test func moveToApplicationsNeedsAnInstalledApp() {
        #expect(!SetupFlow.canContinue(from: .moveToApplications, facts: Self.facts(installed: false)))
        #expect(SetupFlow.canContinue(from: .moveToApplications, facts: Self.facts(installed: true)))
    }

    @Test func permissionsNeedFullDiskAccessButNotNotifications() {
        #expect(!SetupFlow.canContinue(from: .permissions, facts: Self.facts(fda: false)))
        #expect(SetupFlow.canContinue(from: .permissions, facts: Self.facts(fda: true)))
    }

    @Test func storageNeedsAProbe() {
        #expect(!SetupFlow.canContinue(from: .storage, facts: Self.facts()))
        #expect(SetupFlow.canContinue(from: .storage, facts: Self.facts(probe: RepositoryProbe(state: .empty))))
        let existing = RepositoryProbe(state: .existing(AdoptReport(hosts: ["mac"], latestPathsForHost: [], snapshotCount: 3)))
        #expect(SetupFlow.canContinue(from: .storage, facts: Self.facts(probe: existing)))
    }

    @Test func passwordNeedsTheRepositoryReady() {
        #expect(!SetupFlow.canContinue(from: .password, facts: Self.facts(probe: RepositoryProbe(state: .empty))))
        #expect(SetupFlow.canContinue(from: .password, facts: Self.facts(ready: true)))
    }

    @Test func recoveryKitNeedsItConfirmed() {
        #expect(!SetupFlow.canContinue(from: .recoveryKit, facts: Self.facts(ready: true)))
        #expect(SetupFlow.canContinue(from: .recoveryKit, facts: Self.facts(kit: true)))
    }

    @Test func sourcesAndScheduleAlwaysContinueAndDoneDoesNot() {
        #expect(SetupFlow.canContinue(from: .sources, facts: Self.facts()))
        #expect(SetupFlow.canContinue(from: .schedule, facts: Self.facts()))
        #expect(!SetupFlow.canContinue(from: .done, facts: Self.facts(fda: true, ready: true, kit: true)))
    }

    // MARK: Order

    @Test func stepsFollowTheOwnersOrder() {
        let order: [SetupStep] = [
            .moveToApplications, .permissions, .storage, .password, .recoveryKit, .sources, .schedule, .done,
        ]
        #expect(SetupStep.allCases == order)
        for (step, following) in zip(order, order.dropFirst()) {
            #expect(SetupFlow.next(after: step, facts: Self.facts()) == following)
        }
        #expect(SetupFlow.next(after: .done, facts: Self.facts()) == .done)
    }

    // MARK: Resume

    @Test func noPlansStartsFromTheTop() {
        #expect(SetupFlow.resume(saved: nil, plans: [], installed: true) == SetupProgress(planID: nil, step: .permissions, addingPlan: false))
        #expect(SetupFlow.resume(saved: nil, plans: [], installed: false)?.step == .moveToApplications)
    }

    @Test func everyPlanCompleteMeansNothingToResume() {
        let plans = [Self.status("a", .complete), Self.status("b", .complete)]
        #expect(SetupFlow.resume(saved: nil, plans: plans, installed: true) == nil)
    }

    /// A plan that needs a new kit is the recovery-kit window's job, not an unfinished setup.
    @Test func aPlanNeedingANewKitIsNotUnfinishedSetup() {
        let plans = [Self.status("a", .needsNewKit), Self.status("b", .complete)]
        #expect(SetupFlow.resume(saved: nil, plans: plans, installed: true) == nil)
        let saved = SetupProgress(planID: plans[0].plan.id, step: .recoveryKit, addingPlan: false)
        #expect(SetupFlow.resume(saved: saved, plans: plans, installed: true) == nil)
    }

    @Test func anUnfinishedPlanWithSavedProgressResumesAtTheSavedStep() {
        let plan = Self.status("a", .unfinished)
        let saved = SetupProgress(planID: plan.plan.id, step: .sources, addingPlan: false, kitSaved: true)
        #expect(SetupFlow.resume(saved: saved, plans: [plan], installed: true) == saved)
    }

    @Test func anUnfinishedPlanWithoutProgressResumesAtStorage() {
        let plan = Self.status("a", .unfinished)
        #expect(SetupFlow.resume(saved: nil, plans: [plan], installed: true)
            == SetupProgress(planID: plan.plan.id, step: .storage, addingPlan: false))
    }

    @Test func progressForADeletedPlanIsDiscarded() {
        let plan = Self.status("a", .unfinished)
        let saved = SetupProgress(planID: UUID(), step: .schedule, addingPlan: false)
        #expect(SetupFlow.resume(saved: saved, plans: [plan], installed: true)
            == SetupProgress(planID: plan.plan.id, step: .storage, addingPlan: false))
        #expect(SetupFlow.resume(saved: saved, plans: [], installed: true)?.step == .permissions)
        #expect(SetupFlow.resume(saved: saved, plans: [], installed: true)?.planID == nil)
    }

    @Test func progressForACompletedPlanIsDiscarded() {
        let plan = Self.status("a", .complete)
        let saved = SetupProgress(planID: plan.plan.id, step: .schedule, addingPlan: false)
        #expect(SetupFlow.resume(saved: saved, plans: [plan], installed: true) == nil)
    }

    @Test func severalUnfinishedPlansPreferTheSavedOne() {
        let first = Self.status("a", .unfinished)
        let second = Self.status("b", .unfinished)
        let saved = SetupProgress(planID: second.plan.id, step: .password, addingPlan: false)
        #expect(SetupFlow.resume(saved: saved, plans: [first, second], installed: true) == saved)
    }

    @Test func severalUnfinishedPlansWithoutSavedProgressTakeTheFirst() {
        let first = Self.status("a", .unfinished)
        let second = Self.status("b", .unfinished)
        #expect(SetupFlow.resume(saved: nil, plans: [first, second], installed: true)?.planID == first.plan.id)
        #expect(SetupFlow.resume(saved: nil, plans: [Self.status("c", .complete), second, first], installed: true)?.planID == second.plan.id)
    }

    @Test func addingAPlanResumesWithoutRepeatingPermissions() {
        let complete = Self.status("a", .complete)
        let beforePlanExists = SetupProgress(planID: nil, step: .storage, addingPlan: true)
        #expect(SetupFlow.resume(saved: beforePlanExists, plans: [complete], installed: true) == beforePlanExists)

        let adding = Self.status("b", .unfinished)
        let midway = SetupProgress(planID: adding.plan.id, step: .sources, addingPlan: true, kitSaved: true)
        #expect(SetupFlow.resume(saved: midway, plans: [complete, adding], installed: true) == midway)
    }

    @Test func addingAPlanWhoseDraftWasDeletedIsDiscarded() {
        let complete = Self.status("a", .complete)
        let saved = SetupProgress(planID: UUID(), step: .sources, addingPlan: true)
        #expect(SetupFlow.resume(saved: saved, plans: [complete], installed: true) == nil)
    }

    @Test func aFirstRunWithoutAPlanResumesAtTheSavedStep() {
        let saved = SetupProgress(planID: nil, step: .permissions, addingPlan: false)
        #expect(SetupFlow.resume(saved: saved, plans: [], installed: true) == saved)
    }

    @Test func aFirstRunSavedAtMoveToApplicationsResumesThere() {
        let saved = SetupProgress(planID: nil, step: .moveToApplications, addingPlan: false)
        #expect(SetupFlow.resume(saved: saved, plans: [], installed: false) == saved)
        #expect(SetupFlow.resume(saved: saved, plans: [], installed: true)?.step == .permissions)
    }

    @Test func stepsPastTheKitNeedItSaved() {
        let plan = Self.status("a", .unfinished)
        func resumed(_ step: SetupStep, kit: Bool, adding: Bool = false) -> SetupStep? {
            let saved = SetupProgress(planID: plan.plan.id, step: step, addingPlan: adding, kitSaved: kit)
            return SetupFlow.resume(saved: saved, plans: [plan], installed: true)?.step
        }
        #expect(resumed(.sources, kit: false) == .recoveryKit)
        #expect(resumed(.schedule, kit: false) == .recoveryKit)
        #expect(resumed(.done, kit: false) == .recoveryKit)
        #expect(resumed(.sources, kit: false, adding: true) == .recoveryKit)
        #expect(resumed(.sources, kit: true) == .sources)
        #expect(resumed(.done, kit: true) == .done)
        #expect(resumed(.recoveryKit, kit: false) == .recoveryKit)
        #expect(resumed(.password, kit: false) == .password)
    }

    @Test func progressWithoutKitSavedStillDecodes() throws {
        let id = UUID()
        let json = #"{"planID":"\#(id.uuidString)","step":"password","addingPlan":true}"#
        let decoded = try JSONDecoder().decode(SetupProgress.self, from: Data(json.utf8))
        #expect(decoded == SetupProgress(planID: id, step: .password, addingPlan: true, kitSaved: false))
    }

    @Test func progressAheadOfAnUninstalledAppGoesBackToMoveToApplications() {
        let plan = Self.status("a", .unfinished)
        let saved = SetupProgress(planID: plan.plan.id, step: .sources, addingPlan: false, kitSaved: true)
        #expect(SetupFlow.resume(saved: saved, plans: [plan], installed: false)?.step == .moveToApplications)
        let moved = SetupProgress(planID: plan.plan.id, step: .moveToApplications, addingPlan: false)
        #expect(SetupFlow.resume(saved: moved, plans: [plan], installed: true)?.step == .permissions)
    }

    // MARK: Store

    private static func withStore(_ body: (SetupProgressStore, UserDefaults) throws -> Void) rethrows {
        let suite = "SetupProgressStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SetupProgressStore(defaults: defaults), defaults)
    }

    @Test func theStoreRoundTripsAndClears() {
        Self.withStore { store, _ in
            #expect(store.load() == nil)
            let progress = SetupProgress(planID: UUID(), step: .password, addingPlan: true, kitSaved: true)
            store.save(progress)
            #expect(store.load() == progress)
            store.clear()
            #expect(store.load() == nil)
        }
    }

    @Test func corruptDataDecodesToNil() {
        Self.withStore { store, defaults in
            defaults.set(Data("not json".utf8), forKey: SetupProgressStore.key)
            #expect(store.load() == nil)
            defaults.set("a string", forKey: SetupProgressStore.key)
            #expect(store.load() == nil)
            defaults.set(Data(#"{"planID":null,"step":"bogus","addingPlan":false}"#.utf8), forKey: SetupProgressStore.key)
            #expect(store.load() == nil)
        }
    }

    @Test func theStoreUsesTheSetupProgressKey() {
        #expect(SetupProgressStore.key == "setupProgress")
    }
}

@Suite struct SetupFlowOpeningTests {
    private static let planID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func withoutAStatusTheSavedProgressIsKept() {
        let saved = SetupProgress(planID: Self.planID, step: .sources, addingPlan: false, kitSaved: true)
        #expect(SetupFlow.opening(saved: saved, plans: nil, installed: true) == saved)
    }

    @Test func withoutAStatusTheSavedStepIsStillReconciled() {
        let moving = SetupProgress(planID: nil, step: .moveToApplications, addingPlan: false)
        #expect(SetupFlow.opening(saved: moving, plans: nil, installed: true).step == .permissions)
        let pastKit = SetupProgress(planID: Self.planID, step: .schedule, addingPlan: false, kitSaved: false)
        #expect(SetupFlow.opening(saved: pastKit, plans: nil, installed: true).step == .recoveryKit)
    }

    @Test func nothingSavedStartsAtTheFirstStep() {
        #expect(SetupFlow.opening(saved: nil, plans: nil, installed: true).step == .permissions)
        #expect(SetupFlow.opening(saved: nil, plans: [], installed: true).step == .permissions)
    }

    @Test func withPlansItFollowsResume() {
        // Saved progress for a plan that no longer exists, with no plans: a fresh first run.
        let stale = SetupProgress(planID: Self.planID, step: .schedule, addingPlan: false, kitSaved: true)
        let opened = SetupFlow.opening(saved: stale, plans: [], installed: true)
        #expect(opened == SetupProgress(planID: nil, step: .permissions, addingPlan: false))
    }
}

@Suite struct SetupOpenAtLoginTests {
    @Test func aSwitchedOffChoiceSurvivesAQuitAndResume() throws {
        let suite = "restorey-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var draft = SetupDraft(progress: SetupProgress(planID: nil, step: .permissions, addingPlan: false))
        draft.setOpenAtLogin(false)
        SetupProgressStore(defaults: defaults).save(draft.progress)

        // Granting Full Disk Access quits the app; the relaunch loads and resumes the progress.
        let loaded = SetupProgressStore(defaults: defaults).load()
        #expect(loaded?.openAtLogin == false)
        #expect(SetupFlow.resume(saved: loaded, plans: [], installed: true)?.openAtLogin == false)
        #expect(SetupFlow.opening(saved: loaded, plans: nil, installed: true).openAtLogin == false)
    }

    @Test func progressSavedBeforeTheFieldDecodesAsNotSwitched() throws {
        let old = Data(#"{"addingPlan":false,"kitSaved":false,"step":"permissions"}"#.utf8)
        let progress = try JSONDecoder().decode(SetupProgress.self, from: old)
        #expect(progress.openAtLogin == nil)
        #expect(progress.step == .permissions)
    }

}

extension SetupFlowTests {
    // MARK: "+ Add plan…" (Settings → Plans)

    @Test func addingAPlanStartsAFreshSetupAtStorage() {
        let plans = [Self.status("Home", .complete), Self.status("Old", .needsNewKit)]
        let start = SetupFlow.addingPlan(saved: nil, plans: plans, installed: true)
        #expect(start == .start(SetupProgress(planID: nil, step: .storage, addingPlan: true)))
        // Progress left by a setup that has since finished is stale, not a setup to finish.
        let stale = SetupProgress(planID: plans[0].plan.id, step: .done, addingPlan: true, kitSaved: true)
        #expect(SetupFlow.addingPlan(saved: stale, plans: plans, installed: true)
            == .start(SetupProgress(planID: nil, step: .storage, addingPlan: true)))
    }

    /// There is one saved setup at a time: an unfinished plan's setup is finished first rather than overwritten.
    @Test func anUnfinishedPlansSetupIsFinishedFirst() {
        let unfinished = Self.status("Half", .unfinished)
        let plans = [Self.status("Home", .complete), unfinished]
        let saved = SetupProgress(planID: unfinished.plan.id, step: .sources, addingPlan: true, kitSaved: true)
        #expect(SetupFlow.addingPlan(saved: saved, plans: plans, installed: true)
            == .finishFirst(saved, planName: "Half"))
        #expect(SetupFlow.addingPlan(saved: nil, plans: plans, installed: true)
            == .finishFirst(SetupProgress(planID: unfinished.plan.id, step: .storage, addingPlan: false), planName: "Half"))
    }

    /// An add begun but not yet saved by "Check", or a first run with no plan at all, is simply carried on.
    @Test func aSetupWithNoPlanYetIsCarriedOn() {
        let plans = [Self.status("Home", .complete)]
        let draft = SetupProgress(planID: nil, step: .storage, addingPlan: true)
        #expect(SetupFlow.addingPlan(saved: draft, plans: plans, installed: true) == .resume(draft))
        #expect(SetupFlow.addingPlan(saved: nil, plans: [], installed: true)
            == .resume(SetupProgress(planID: nil, step: .permissions, addingPlan: false)))
    }
}
