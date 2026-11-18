import Testing
@testable import RestoreyCore

/// The shapes that carry a status (Task 17b, HIG Accessibility: don't rely on colour alone). Each outcome has its own
/// outline, so two of them are never told apart by colour only, and each has words for VoiceOver.
struct SeveritySymbolsTests {
    @Test func aWarningIsATriangleAndAnErrorIsAnOctagon() {
        #expect(Severity.warning.symbolName == "exclamationmark.triangle.fill")
        #expect(Severity.error.symbolName == "xmark.octagon.fill")
        #expect(Severity.warning.accessibilityLabel == "Warning")
        #expect(Severity.error.accessibilityLabel == "Error")
    }

    @Test func everyHistoryOutcomeHasItsOwnShape() {
        let kinds: [HistoryRow.Kind] = [.success, .warning, .failure, .skipped]
        #expect(kinds.map(\.symbolName) == [
            "checkmark.circle.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill", "minus.circle",
        ])
        #expect(Set(kinds.map(\.symbolName)).count == kinds.count)
        #expect(kinds.map(\.accessibilityLabel) == ["Succeeded", "Finished with a warning", "Failed", "Not run"])
    }

    @Test func aHistoryWarningAndFailureUseTheSeveritySymbols() {
        #expect(HistoryRow.Kind.warning.symbolName == Severity.warning.symbolName)
        #expect(HistoryRow.Kind.failure.symbolName == Severity.error.symbolName)
    }
}
