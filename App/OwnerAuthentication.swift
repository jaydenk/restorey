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

    /// `reason` completes macOS's "Restorey is trying to …", so it starts with a verb in lower case.
    static func confirm(reason: String) async -> Outcome {
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
            why = "macOS isn't letting Restorey show its prompt right now. Try again once you're logged in and the screen is unlocked"
        default:
            why = error?.localizedDescription ?? "macOS gave no reason"
        }
        return FormValidation.sentence("This Mac can't confirm it's you, so the passwords and keys stay hidden: \(why)")
    }
}
