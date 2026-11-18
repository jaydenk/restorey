import Testing
@testable import RestoreyCore

/// The steppers beside the number fields (Task 17c, P14): what a click writes into the field. The fields' own checks
/// are unchanged.
struct StepperTextTests {
    @Test func aCountStepsAndStaysInRange() {
        #expect(StepperText.count("24", by: 1) == "25")
        #expect(StepperText.count(" 24 ", by: -1) == "23")
        #expect(StepperText.count("0", by: -1) == "0")
        #expect(StepperText.count("9999", by: 1) == "9999")
        // Whatever reads as no number steps from 0, so the stepper always does something.
        #expect(StepperText.count("", by: 1) == "1")
        #expect(StepperText.count("abc", by: 1) == "1")
        #expect(StepperText.count("abc", by: -1) == "0")
        // What a step writes always passes the field's check.
        for text in ["", "0", "5", "9999", "x"] {
            #expect(ScheduleForm.countProblem(StepperText.count(text, by: 1)) == nil)
            #expect(ScheduleForm.countProblem(StepperText.count(text, by: -1)) == nil)
        }
    }

    @Test func anUploadLimitStepsFromNoLimitAndBackToIt() {
        #expect(StepperText.uploadLimit("", by: 1) == "1")
        #expect(StepperText.uploadLimit("1", by: -1) == "")
        #expect(StepperText.uploadLimit("", by: -1) == "")
        #expect(StepperText.uploadLimit("5", by: 1) == "6")
        #expect(StepperText.uploadLimit("1.5", by: 1) == "2.5")
        #expect(StepperText.uploadLimit("0.5", by: -1) == "")
        #expect(StepperText.uploadLimit(" 2 ", by: -1) == "1")
        #expect(StepperText.uploadLimit("fast", by: 1) == "1")
        // What a step writes is always a valid limit, or empty for none.
        for text in ["", "1", "1.25", "40"] {
            for step in [1, -1] {
                let next = StepperText.uploadLimit(text, by: step)
                guard case .success = FormValidation.uploadLimit(next) else {
                    Issue.record("\(text) by \(step) wrote \(next), which isn't a limit")
                    continue
                }
            }
        }
    }
}
