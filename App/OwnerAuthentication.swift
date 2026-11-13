import Foundation
import LocalAuthentication

/// The gate in front of a plan's secrets outside setup (UI design §5 "Restore Files…" and §7; Ruling P2-5): Touch
/// ID, or the login password when Touch ID isn't available or is declined (`.deviceOwnerAuthentication`).
@MainActor
enum OwnerAuthentication {
    /// True once the owner has authenticated. False when they cancel, fail, or the Mac can't ask (no password
    /// set, say); the caller shows its own sentence and offers to try again. `reason` completes macOS's
    /// "Restorey is trying to …", so it starts with a verb in lower case.
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
