import Foundation
import Testing
@testable import RestoreyCore

/// Closing the main window or quitting with unsaved plan edits asks Save, Don't Save or Cancel (Ruling R1, fix round 2).
struct SaveQuestionTests {
    @Test func aPlansQuestionNamesItAndWarnsWhenSavingPauses() {
        #expect(SaveQuestion.plan(name: "MacBook", pausesBackups: false) == SaveQuestion(
            message: "Do you want to save the changes to “MacBook”?",
            information: "If you don’t save, your changes are lost."))
        #expect(SaveQuestion.plan(name: "MacBook", pausesBackups: true).information
            == "Saving pauses backups until you save a new recovery kit. If you don’t save, your changes are lost.")
    }

    /// Only a plan's edits are asked about: the Settings window saves as it goes.
    @Test func onlyAPlanIsAskedAbout() {
        #expect(UnsavedSettings.toAsk(plan: false) == [])
        #expect(UnsavedSettings.toAsk(plan: true) == [.plan])
        #expect(UnsavedSettings.plan.section == MainSection.plans)
    }
}
