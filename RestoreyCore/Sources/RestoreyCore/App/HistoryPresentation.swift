import Foundation

/// One run in the History list (UI design §6.4): when, which plan, what step, how it ended in the menu's wording,
/// what it added and how long it took where known, and its log.
public struct HistoryRow: Sendable, Equatable, Identifiable {
    /// How the row's dot is drawn. A skip, pause or stop by the system is never a failure.
    public enum Kind: Sendable, Equatable {
        case success
        case warning
        case failure
        /// Skipped, paused, cancelled or stopped by the system: grey.
        case skipped
    }

    public var id: UUID
    public var planID: UUID
    /// "14:16" today, "Yesterday, 09:05", otherwise "9 Nov, 09:05", in local time.
    public var time: String
    public var plan: String
    /// "Backup", "Tidy", "Prune", "Check", …
    public var operation: String
    /// "Backed up", "Old snapshots tidied", "Skipped: Photos isn't connected", "Backup failed", …
    public var outcome: String
    /// What else is known, joined with " · ": the failure's reason or unreadable files, the size added, the duration.
    public var detail: String?
    public var kind: Kind
    /// The run's log, relative to the logs folder (`HistoryPresentation.logURL`); nil when the run never reached
    /// restic.
    public var logFile: String?
}

/// Which runs the History list shows.
public enum HistoryFilter: String, CaseIterable, Sendable, Identifiable {
    case everything
    /// Backups that saved the data (success, unchanged or warning, Ruling P2-4).
    case backups
    /// Failures and warnings.
    case problems
    /// Skipped, paused, cancelled or stopped by the system.
    case notRun

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everything: "Everything"
        case .backups: "Backups"
        case .problems: "Problems"
        case .notRun: "Skipped and paused"
        }
    }
}

/// Turns the agent's run records (`history`) into the History list's rows. Pure, like `MenuPresentation`.
public enum HistoryPresentation {
    /// Newest first, for `plan` (nil: every plan) and `filter`.
    public static func rows(
        _ records: [RunRecord], plan: UUID?, filter: HistoryFilter, planNames: [UUID: String], now: Date,
        calendar: Calendar, locale: Locale
    ) -> [HistoryRow] {
        records
            .filter { plan == nil || $0.planID == plan }
            .sorted { $0.endedAt > $1.endedAt }
            .compactMap { record in
                let row = row(record, planNames: planNames, now: now, calendar: calendar, locale: locale)
                return matches(record, row, filter) ? row : nil
            }
    }

    private static func matches(_ record: RunRecord, _ row: HistoryRow, _ filter: HistoryFilter) -> Bool {
        switch filter {
        case .everything: true
        case .backups: PlanRunHistory.savedData(record)
        case .problems: row.kind == .warning || row.kind == .failure
        case .notRun: row.kind == .skipped
        }
    }

    public static func row(
        _ record: RunRecord, planNames: [UUID: String], now: Date, calendar: Calendar, locale: Locale
    ) -> HistoryRow {
        var details: [String] = []
        let outcome: String
        let kind: HistoryRow.Kind
        switch record.outcome {
        case .success, .unchanged:
            outcome = succeeded(record.operation)
            kind = .success
        case .warning(let unreadable):
            outcome = succeeded(record.operation)
            details.append("\(unreadable) \(unreadable == 1 ? "file" : "files") couldn't be read")
            kind = .warning
        case .paused:
            outcome = "Paused"
            kind = .skipped
        case .cancelled:
            outcome = "Cancelled"
            kind = .skipped
        case .stoppedBySystem:
            outcome = "Stopped: the Mac was restarting, shutting down or logging out"
            kind = .skipped
        case .skipped(let reason):
            outcome = reason.summary
            kind = .skipped
        case .locked:
            outcome = "Repository busy: another restic held its lock"
            kind = .warning
        case .repositoryMissing where record.operation == .catConfig:
            // Only probes run `cat config`, and nothing there is the answer setup expects for a new address
            // ("Nothing here yet."), not a failure (live finding 1).
            outcome = "No repository there yet"
            kind = .success
        case .wrongPassword, .repositoryMissing, .credentialsUnavailable, .interrupted, .failed:
            if case .forgetSnapshots = record.operation {
                outcome = "Couldn't remove earlier snapshots"
            } else {
                outcome = "\(operationTitle(record.operation)) failed"
            }
            if let reason = record.outcome.failureReason { details.append(reason) }
            kind = .failure
        }
        if let summary = record.summary, record.operation == .backup {
            details.append(DisplayFormat.size(Int64(summary.dataAdded), locale: locale))
        }
        if let seconds = duration(record) { details.append(DisplayFormat.duration(seconds: seconds)) }
        return HistoryRow(
            id: record.id, planID: record.planID, time: time(record.endedAt, now: now, calendar: calendar, locale: locale),
            plan: planNames[record.planID] ?? "Deleted plan", operation: operationTitle(record.operation),
            outcome: outcome, detail: details.isEmpty ? nil : details.joined(separator: " · "), kind: kind,
            logFile: record.logFile.isEmpty ? nil : record.logFile)
    }

    /// restic's own measure for a backup, otherwise the record's start to end. A run that never started (a skip)
    /// has none.
    private static func duration(_ record: RunRecord) -> TimeInterval? {
        if let summary = record.summary, summary.totalDuration > 0 { return summary.totalDuration }
        let seconds = record.endedAt.timeIntervalSince(record.startedAt)
        return seconds > 0 ? seconds : nil
    }

    private static func succeeded(_ operation: ResticOperation) -> String {
        switch operation {
        case .backup: "Backed up"
        case .forget(let dryRun): dryRun ? "Snapshots to tidy counted" : "Old snapshots tidied"
        case .prune: "Unused data removed"
        case .check: "Repository checked"
        case .unlock: "Stale locks removed"
        case .stats: "Size measured"
        case .initRepository: "Repository created"
        case .snapshots: "Snapshots listed"
        case .catConfig: "Repository found"
        // Never recorded (a dry run records nothing), but named in case one ever is.
        case .forgetPreview: "Earlier snapshots counted"
        case .forgetSnapshots(let ids): EarlierSnapshotsText.historyOutcome(removed: ids.count)
        }
    }

    private static func operationTitle(_ operation: ResticOperation) -> String {
        switch operation {
        case .backup: "Backup"
        case .forget, .forgetPreview, .forgetSnapshots: "Tidy"
        case .prune: "Prune"
        case .check: "Check"
        case .unlock: "Unlock"
        case .stats: "Size"
        case .initRepository: "Create"
        case .snapshots: "Snapshots"
        case .catConfig: "Probe"
        }
    }

    private static func time(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let clock = DisplayFormat.time(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(clock)"
        }
        return "\(DisplayFormat.dayAndMonth(date, calendar: calendar, locale: locale)), \(clock)"
    }

    /// The run's log file to open, or nil. The path comes from the agent, relative to the logs folder; only a file
    /// under its `runs/` folder is ever opened, so a path that climbs out (`..`) or is absolute opens nothing.
    public static func logURL(_ logFile: String, logsDirectory: URL) -> URL? {
        guard !logFile.isEmpty, !logFile.hasPrefix("/") else { return nil }
        let runs = logsDirectory.appendingPathComponent("runs", isDirectory: true).standardizedFileURL.path + "/"
        let url = logsDirectory.appendingPathComponent(logFile).standardizedFileURL
        return url.path.hasPrefix(runs) ? url : nil
    }
}
