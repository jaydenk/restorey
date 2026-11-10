import Foundation
import RestoreyCore

// A stand-in the plan runner needs until the v0.1 engine's check-in service replaces it. Until then the
// README says that check-in pings aren't live yet.

/// Logs each ping instead of sending it. The check-in service replaces this.
struct InterimCheckInSender: CheckInSending {
    let log: AppLog

    func send(_ ping: CheckInPing, planID: UUID) async {
        let name =
            switch ping {
            case .start: "start"
            case .success: "success"
            case .fail: "fail"
            }
        log.info("Check-in \(name) ping for plan \(planID.uuidString) not sent: this build doesn't send check-in pings yet")
    }
}
