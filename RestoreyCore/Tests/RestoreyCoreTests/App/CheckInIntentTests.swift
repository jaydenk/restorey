import Foundation
import Testing
@testable import RestoreyCore

/// Ruling R53: what a form's check-in URL field and "Remove check-in URL" control mean for a save.
struct CheckInIntentTests {
    /// The field can't show a saved URL, so empty must never remove one.
    @Test func emptyFieldKeepsTheSavedState() throws {
        #expect(try checkInIntent(existing: true, field: "", remove: false) == CheckInIntent(hasCheckInURL: true, secret: nil))
        #expect(try checkInIntent(existing: false, field: "", remove: false) == CheckInIntent(hasCheckInURL: false, secret: nil))
        #expect(try checkInIntent(existing: true, field: "  \n", remove: false) == CheckInIntent(hasCheckInURL: true, secret: nil))
    }

    @Test func nonEmptyFieldSetsIt() throws {
        for existing in [true, false] {
            #expect(try checkInIntent(existing: existing, field: " https://hc.example/ping/a ", remove: false)
                == CheckInIntent(hasCheckInURL: true, secret: "https://hc.example/ping/a"))
        }
    }

    @Test func removeClearsIt() throws {
        #expect(try checkInIntent(existing: true, field: "", remove: true) == CheckInIntent(hasCheckInURL: false, secret: nil))
    }

    @Test func fieldTogetherWithRemoveIsRefused() {
        #expect(throws: CheckInIntentError.urlAndRemove) {
            try checkInIntent(existing: true, field: "https://hc.example/ping/a", remove: true)
        }
        #expect(CheckInIntentError.urlAndRemove.description
            == "Either enter a new check-in URL or remove it, not both.")
    }
}
