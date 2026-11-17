import Foundation
import Testing
@testable import RestoreyCore

/// Closing Settings or quitting with unsaved edits asks Save, Don't Save or Cancel (Ruling R1, fix round 2), for a
/// plan's edits and, since Task 15 fix round 1 (I1), for the Network section's too.
struct SaveQuestionTests {
    @Test func aPlansQuestionNamesItAndWarnsWhenSavingPauses() {
        #expect(SaveQuestion.plan(name: "MacBook", pausesBackups: false) == SaveQuestion(
            message: "Do you want to save the changes to “MacBook”?",
            information: "If you don't save, your changes are lost."))
        #expect(SaveQuestion.plan(name: "MacBook", pausesBackups: true).information
            == "Saving pauses backups until you save a new recovery kit. If you don't save, your changes are lost.")
    }

    @Test func theNetworkQuestion() {
        #expect(SaveQuestion.network == SaveQuestion(
            message: "Do you want to save the changes to the network settings?",
            information: "If you don't save, your changes are lost."))
    }

    /// Each unsaved section is asked about in turn, the plan first (its question names it), and nothing is asked
    /// when nothing is unsaved.
    @Test func theOrderOfTheQuestions() {
        #expect(UnsavedSettings.toAsk(plan: false, network: false) == [])
        #expect(UnsavedSettings.toAsk(plan: true, network: false) == [.plan])
        #expect(UnsavedSettings.toAsk(plan: false, network: true) == [.network])
        #expect(UnsavedSettings.toAsk(plan: true, network: true) == [.plan, .network])
        #expect(UnsavedSettings.plan.section == .plans)
        #expect(UnsavedSettings.network.section == .network)
    }

    /// P7: the window's edited dot shows exactly when a close or quit would ask.
    @Test func theEditedIndicatorFollowsTheUnsavedEdits() {
        #expect(!UnsavedSettings.isEdited(plan: false, network: false))
        #expect(UnsavedSettings.isEdited(plan: true, network: false))
        #expect(UnsavedSettings.isEdited(plan: false, network: true))
        #expect(UnsavedSettings.isEdited(plan: true, network: true))
    }
}
