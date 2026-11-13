import Foundation
import Testing

@testable import RestoreyCore

@Suite struct PasswordStepTests {
    private static let report = AdoptReport(hosts: ["pepper", "nas"], latestPathsForHost: ["/Users/me"], snapshotCount: 3)

    private static func progress(created: Bool = false, adoption: AdoptReport? = nil) -> SetupProgress {
        var progress = SetupProgress(planID: UUID(), step: .password, addingPlan: false)
        progress.repositoryCreated = created
        progress.adoption = adoption
        return progress
    }

    @Test func nothingProbedYetIsProbing() {
        #expect(PasswordStep.decide(probe: nil, progress: Self.progress()) == .probing)
    }

    @Test func emptyAddressOffersCreate() {
        #expect(PasswordStep.decide(probe: .empty, progress: Self.progress()) == .create)
    }

    @Test func aRepositoryTheStandInCantOpenAsksForItsPassword() {
        #expect(PasswordStep.decide(probe: .passwordRejected, progress: Self.progress()) == .open)
    }

    @Test func createdThenQuitIsReadyWithoutAnotherProbe() {
        // The repository was created and the app quit before the step moved on: nothing to repeat.
        #expect(PasswordStep.decide(probe: nil, progress: Self.progress(created: true)) == .ready)
        #expect(PasswordStep.decide(probe: .existing(Self.report), progress: Self.progress(created: true)) == .ready)
    }

    @Test func openedButNotAdoptedResumesOnTheAdoptPath() {
        // "Open Repository" saved the right password, then setup closed before "Use This Repository": the
        // resumed probe opens it, but this setup didn't make it, so it must still be adopted.
        #expect(PasswordStep.decide(probe: .existing(Self.report), progress: Self.progress()) == .adopt(Self.report))
    }

    @Test func adoptedThenQuitIsReady() {
        #expect(PasswordStep.decide(probe: nil, progress: Self.progress(adoption: Self.report)) == .ready)
    }

    @Test func progressFromBeforeTheseFactsDecodesWithoutThem() throws {
        let id = UUID()
        let old = #"{"planID":"\#(id.uuidString)","step":"password","addingPlan":false,"kitSaved":false}"#
        let decoded = try JSONDecoder().decode(SetupProgress.self, from: Data(old.utf8))
        #expect(!decoded.repositoryCreated)
        #expect(decoded.adoption == nil)
    }

    @Test func theFactsRoundTripAndHoldNoSecret() throws {
        let progress = Self.progress(created: true, adoption: Self.report)
        let data = try JSONEncoder().encode(progress)
        #expect(try JSONDecoder().decode(SetupProgress.self, from: data) == progress)
    }

    @Test func aNewAddressForgetsWhatWasFoundAtTheOldOne() {
        var draft = SetupDraft(progress: Self.progress(created: true, adoption: Self.report))
        draft.probe = RepositoryProbe(state: .existing(Self.report))
        draft.forgetRepository()
        #expect(!draft.progress.repositoryCreated)
        #expect(draft.progress.adoption == nil)
        #expect(draft.probe == nil)
    }

    @Test func forgettingThePlanStartsAgainAtStorage() {
        var progress = Self.progress(created: true, adoption: Self.report)
        progress.step = .schedule
        progress.kitSaved = true
        var draft = SetupDraft(progress: progress)
        draft.forgetPlan()
        #expect(draft.progress == SetupProgress(planID: nil, step: .storage, addingPlan: false))
        #expect(draft.plan == nil)
    }
}
