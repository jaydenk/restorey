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
        let saved = SetupProgress(planID: plan.plan.id, step: .sources, addingPlan: false)
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
        let midway = SetupProgress(planID: adding.plan.id, step: .sources, addingPlan: true)
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

    @Test func progressAheadOfAnUninstalledAppGoesBackToMoveToApplications() {
        let plan = Self.status("a", .unfinished)
        let saved = SetupProgress(planID: plan.plan.id, step: .sources, addingPlan: false)
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
            let progress = SetupProgress(planID: UUID(), step: .password, addingPlan: true)
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
