import Testing
@testable import RestoreyCore

/// Showing a plan's passwords and keys in Restore Files and the kit window (owner ruling, 13 Nov): the button keeps
/// them shown until it hides them, the window stops being key or closes; holding Option is a peek.
struct SecretRevealTests {
    @Test func theButtonKeepsThemShownUntilHidden() {
        var reveal = SecretReveal()
        reveal.becameKey()
        #expect(!reveal.visible)
        reveal.approvedByButton()
        #expect(reveal.visible)
        #expect(reveal.buttonTitle(authenticated: true) == "Hide Passwords and Keys")
        reveal.toggle()
        #expect(!reveal.visible)
        #expect(reveal.buttonTitle(authenticated: true) == "Show Passwords and Keys")
        reveal.toggle()
        #expect(reveal.visible)
    }

    /// The first reveal in an opening asks for the owner, so its button says so with an ellipsis.
    @Test func beforeTheOwnerIsConfirmedTheButtonAsks() {
        #expect(SecretReveal().buttonTitle(authenticated: false) == "Show Passwords and Keys…")
    }

    @Test func optionIsAPeek() {
        var reveal = SecretReveal()
        reveal.becameKey()
        reveal.optionChanged(true)
        #expect(reveal.visible)
        reveal.optionChanged(false)
        #expect(!reveal.visible)
        reveal.approvedByButton()
        reveal.optionChanged(true)
        reveal.optionChanged(false)
        #expect(reveal.visible)
    }

    /// A window that isn't key isn't being looked at: what was shown goes back to dots.
    @Test func resigningKeyOrClosingHidesThem() {
        var reveal = SecretReveal()
        reveal.becameKey()
        reveal.approvedByButton()
        reveal.optionChanged(true)
        reveal.resignedKey()
        #expect(!reveal.visible)
        reveal.becameKey()
        reveal.approvedByButton()
        reveal.reset()
        #expect(!reveal.visible)
    }

    /// Fix round 2, minor 4: an approval whose secrets arrive while the window isn't key (the owner moved on while
    /// they were fetched) shows nothing; the window isn't being looked at.
    @Test func anApprovalWhileTheWindowIsntKeyIsIgnored() {
        var reveal = SecretReveal()
        reveal.approvedByButton()
        #expect(!reveal.visible)
        reveal.becameKey()
        reveal.resignedKey()
        reveal.approvedByButton()
        #expect(!reveal.visible)
        reveal.becameKey()
        reveal.approvedByButton()
        #expect(reveal.visible)
    }
}
