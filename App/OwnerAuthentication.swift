import AppKit
import Foundation
import LocalAuthentication
import RestoreyCore

/// The gate in front of a plan's secrets outside setup (UI design §5 "Restore Files…" and §7; Ruling P2-5): Touch
/// ID, or the login password when Touch ID isn't available or is declined (`.deviceOwnerAuthentication`).
@MainActor
enum OwnerAuthentication {
    enum Outcome: Equatable {
        case confirmed
        /// The owner cancelled or didn't get it right: asking again can work.
        case declined
        /// This Mac can't ask at all; the sentence says why, in plain words. Asking again won't help until that
        /// changes.
        case unavailable(String)
    }

    /// `reason` completes macOS's "Restorey is trying to …", so it starts with a verb in lower case. When the
    /// prompt has gone, whichever way it ended, the window of `returningTo` is made key again. Nothing asks for
    /// activation here (O1 diagnosis): macOS itself gives the front back to Restorey, an ordinary app while the
    /// window is open (`WindowActivation`), and a request with no user input behind it is always refused anyway.
    static func confirm(reason: String, returningTo window: AppWindowKind) async -> Outcome {
        let outcome = await ask(reason: reason)
        // Only a window still on screen: one closed during the prompt stays closed (review M1). A closed window can
        // outlive its closing (it isn't released when closed), and ordering it front again would show an empty
        // window that Restorey's activation policy no longer counts.
        NSApplication.shared.windows
            .first { $0.identifier?.rawValue == window.rawValue && $0.isVisible }?
            .makeKeyAndOrderFront(nil)
        return outcome
    }

    private static func ask(reason: String) async -> Outcome {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            return .unavailable(sentence(unavailable))
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .confirmed : .declined
        } catch let error as LAError where [.passcodeNotSet, .notInteractive].contains(error.code) {
            return .unavailable(sentence(error as NSError))
        } catch {
            return .declined
        }
    }

    /// "This Mac can't confirm it's you" and why, for a Mac that can't ask (`canEvaluatePolicy` failed).
    static func sentence(_ error: NSError?) -> String {
        let why: String
        switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .passcodeNotSet?:
            why = "this user account has no login password, so macOS has nothing to check. Set one in System Settings → Users & Groups"
        case .notInteractive?:
            why = "macOS isn’t letting Restorey show its prompt right now. Try again once you’re logged in and the screen is unlocked"
        default:
            why = error?.localizedDescription ?? "macOS gave no reason"
        }
        return FormValidation.sentence("This Mac can’t confirm it’s you, so the passwords and keys stay hidden: \(why)")
    }
}
