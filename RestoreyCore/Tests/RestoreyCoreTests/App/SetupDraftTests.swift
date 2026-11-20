import Foundation
import Testing

@testable import RestoreyCore

@Suite struct SetupDraftTests {
    private static let planID = UUID(uuidString: "6F9A3C1E-2B4D-4E8F-9A1B-0C2D3E4F5A6B")!

    private static func draft(at step: SetupStep = .storage) -> SetupDraft {
        SetupDraft(progress: SetupProgress(planID: planID, step: step, addingPlan: false))
    }

    @Test func secretsAreKeptWithinAStep() {
        var draft = Self.draft()
        draft.setSecret("key id", for: .s3AccessKeyID(Self.planID))
        draft.setSecret("pa ss\"wörd'\n", for: .repositoryPassword(Self.planID))
        #expect(draft.secret(.s3AccessKeyID(Self.planID)) == "key id")
        #expect(draft.secret(.repositoryPassword(Self.planID)) == "pa ss\"wörd'\n")
        draft.setSecret(nil, for: .s3AccessKeyID(Self.planID))
        #expect(draft.secret(.s3AccessKeyID(Self.planID)) == nil)
    }

    @Test func changingStepClearsSecretsAndKeepsProgress() {
        var draft = Self.draft()
        draft.setSecret("secret", for: .s3SecretAccessKey(Self.planID))
        draft.go(to: .password)
        #expect(draft.secrets.isEmpty)
        #expect(draft.step == .password)
        #expect(draft.progress.planID == Self.planID)
    }

    @Test func goingToTheSameStepKeepsSecrets() {
        var draft = Self.draft()
        draft.setSecret("secret", for: .s3SecretAccessKey(Self.planID))
        draft.go(to: .storage)
        #expect(draft.secret(.s3SecretAccessKey(Self.planID)) == "secret")
    }

    @Test func closingClearsSecretsButNotTheStep() {
        var draft = Self.draft(at: .password)
        draft.setSecret("secret", for: .repositoryPassword(Self.planID))
        draft.setSecret("https://hc-ping.com/x", for: .checkInURL(Self.planID))
        draft.close()
        #expect(draft.secrets.isEmpty)
        #expect(draft.step == .password)
    }

    @Test func descriptionsNeverShowSecrets() {
        var draft = Self.draft()
        draft.setSecret("hunter2-secret", for: .repositoryPassword(Self.planID))
        for text in [draft.description, draft.debugDescription, String(reflecting: draft), "\(draft)", String(describing: Mirror(reflecting: draft).children.map(\.value))] {
            #expect(!text.contains("hunter2-secret"))
        }
        #expect(draft.description.contains("repository-password"))
    }

    @Test func headingsFollowTheMockup() {
        #expect(SetupStep.moveToApplications.heading(addingPlan: false) == "Step 1 of 6 · Permissions")
        #expect(SetupStep.permissions.heading(addingPlan: false) == "Step 1 of 6 · Permissions")
        #expect(SetupStep.storage.heading(addingPlan: false) == "Step 2 of 6 · Where backups go")
        #expect(SetupStep.schedule.heading(addingPlan: false) == "Step 6 of 6 · Schedule")
        #expect(SetupStep.storage.heading(addingPlan: true) == "Step 1 of 5 · Where backups go")
        #expect(SetupStep.done.heading(addingPlan: false) == "Done")
    }

    @Test func theKitTickAndThePlanAreRecordedInTheProgress() {
        var draft = SetupDraft(progress: SetupProgress(planID: nil, step: .storage, addingPlan: false))
        draft.setPlanID(Self.planID)
        draft.go(to: .recoveryKit)
        #expect(!draft.progress.kitSaved)
        draft.setKitSaved(true, digest: "kit-digest")
        #expect(draft.progress == SetupProgress(
            planID: Self.planID, step: .recoveryKit, addingPlan: false, kitSaved: true, kitDigest: "kit-digest"))
        // The probe isn't a secret: a step change keeps it.
        draft.probe = RepositoryProbe(state: .passwordRejected)
        draft.go(to: .sources)
        #expect(draft.probe == RepositoryProbe(state: .passwordRejected))
    }

    /// Task 14b: the adoption step's confirmed opt-in is kept in the progress until Done hands it to the agent, and
    /// goes with the repository when the address changes.
    @Test func theEarlierSnapshotsChoiceIsRecordedAndGoesWithTheRepository() throws {
        var draft = Self.draft(at: .password)
        let choice = EarlierSnapshotsConfirmation(scope: .beforeAdoption, snapshotIDs: [String(repeating: "c", count: 64)])
        draft.setEarlierRemoval(choice)
        #expect(draft.progress.earlierRemoval == choice)
        let decoded = try JSONDecoder().decode(SetupProgress.self, from: JSONEncoder().encode(draft.progress))
        #expect(decoded.earlierRemoval == choice)
        draft.forgetRepository()
        #expect(draft.progress.earlierRemoval == nil)
        draft.setEarlierRemoval(choice)
        draft.setEarlierRemoval(nil)
        #expect(draft.progress.earlierRemoval == nil)
    }

    @Test func environmentValuesFollowTheirRowNotItsName() {
        // Typed into a row before its name is final: renaming the row must not orphan the value.
        var draft = Self.draft()
        let row = UUID()
        draft.setEnvironmentValue("s3cr3t", for: row)
        #expect(draft.environmentValue(row) == "s3cr3t")
        #expect(!draft.description.contains("s3cr3t"))
        #expect(!String(reflecting: draft).contains("s3cr3t"))
        draft.go(to: .password)
        #expect(draft.environmentValue(row) == nil)
        draft.setEnvironmentValue("again", for: row)
        draft.close()
        #expect(draft.environmentValue(row) == nil)
    }
}
