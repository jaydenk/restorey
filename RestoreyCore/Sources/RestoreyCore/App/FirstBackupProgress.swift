import Foundation

/// What setup's Done step shows once "Start first backup" has been pressed (UI design §4 step 7): the plan's
/// live line, worded as the menu words it. A backup waiting its turn (behind the size measurement an adopt
/// queues, or another plan on the same repository) has no progress yet and says so, rather than a bare
/// "Backing up". Pure; `SetupModel` feeds it the latest status.
public struct FirstBackupProgress: Sendable, Equatable {
    public var title: String
    public var detail: String?
    /// 0 to 1 once restic reports progress.
    public var fraction: Double?
    /// The backup has ended (successfully or not): the plan's line shows how.
    public var finished: Bool
    public var severity: Severity?

    public init(title: String, detail: String? = nil, fraction: Double? = nil, finished: Bool = false, severity: Severity? = nil) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.finished = finished
        self.severity = severity
    }

    /// The plan's newest records when Start was pressed, so the backup's own ending can be told from records
    /// that were already there, or that other steps (an adopt's size measurement) add meanwhile.
    public struct Baseline: Sendable, Equatable {
        /// The newest backup record of any outcome (`PlanStatus.latestBackupRecord`).
        public var lastBackupRecord: UUID?
        public var lastBackup: UUID?

        public init(_ plan: PlanStatus?) {
            lastBackupRecord = plan?.latestBackupRecord?.id
            lastBackup = plan?.lastBackup?.id
        }
    }

    /// - Parameters:
    ///   - plan: the plan's latest status, nil until one arrives.
    ///   - baseline: from the status when Start was pressed. The backup has ended once a newer backup that
    ///     saved the data arrives, or a newer record of a backup (a failure or a skip).
    public static func make(
        plan: PlanStatus?, baseline: Baseline, bytesPerSecond: Double?, now: Date, calendar: Calendar,
        locale: Locale
    ) -> FirstBackupProgress {
        guard let plan else { return FirstBackupProgress(title: "Starting the first backup…") }
        let line = MenuPresentation.planLine(
            for: plan, bytesPerSecond: bytesPerSecond, now: now, calendar: calendar, locale: locale)
        let backedUp = plan.lastBackup.map { $0.id != baseline.lastBackup } ?? false
        switch plan.phase {
        case .running(let progress, let retrying):
            if backedUp {
                // The backup has saved the data; the run goes on with its maintenance (forget, check).
                var settled = plan
                settled.phase = .idle
                let done = MenuPresentation.planLine(
                    for: settled, bytesPerSecond: nil, now: now, calendar: calendar, locale: locale)
                return FirstBackupProgress(
                    title: done.status, detail: "Restorey is tidying the repository after it.", finished: true,
                    severity: done.severity)
            }
            guard let progress else {
                if retrying != nil { return FirstBackupProgress(title: line.status, detail: line.detail) }
                // No progress yet: waiting its turn (behind an adopt's size measurement, or another plan on the
                // same repository), or restic hasn't reported yet. A small backup may never report before it ends.
                return FirstBackupProgress(
                    title: "Waiting to start",
                    detail: "The first backup starts as soon as the repository is free.")
            }
            let percent = Int((min(max(progress.percentDone, 0), 1) * 100).rounded(.down))
            return FirstBackupProgress(title: "Backing up — \(percent)%", detail: line.detail, fraction: line.progress)
        case .paused:
            return FirstBackupProgress(title: line.status, detail: line.detail)
        case .idle, .skipped, .stopped:
            // A newer backup record of any outcome (a failure, a skip), whatever steps ran after it.
            let backupEnded = plan.latestBackupRecord.map { $0.id != baseline.lastBackupRecord } ?? false
            guard backedUp || backupEnded else { return FirstBackupProgress(title: "Starting the first backup…") }
            return FirstBackupProgress(title: line.status, detail: line.detail, finished: true, severity: line.severity)
        }
    }
}
