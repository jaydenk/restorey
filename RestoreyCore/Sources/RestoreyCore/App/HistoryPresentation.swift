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
    /// When the run ended: what the Time column sorts by.
    public var endedAt: Date
    /// "14:16" today, "Yesterday, 09:05", otherwise "9 Nov, 09:05", in local time.
    public var time: String
    public var plan: String
    /// "Backup", "Tidy", "Prune", "Check", …
    public var operation: String
    /// "Backed up", "Old snapshots tidied", "Skipped: Photos isn't connected", "Backup failed", …
    public var outcome: String
    /// What else is known, joined with " · ": the failure's reason or unreadable files, the size added, the duration.
    public var detail: String?
    /// The part of `detail` that belongs with the outcome (the failure's reason or the unreadable files), for the
    /// History table's Outcome column; the size and duration have columns of their own (Task 17c).
    public var note: String?
    /// The size a backup added ("1.2 GB"), and the bytes it sorts by; nil for any other run.
    public var added: String?
    public var addedBytes: Int64?
    /// How long the run took ("3 min"), and the seconds it sorts by; nil for a run that never started.
    public var duration: String?
    public var durationSeconds: TimeInterval?
    public var kind: Kind
    /// The run's log, relative to the logs folder (`HistoryPresentation.logURL`); nil when the run never reached
    /// restic.
    public var logFile: String?
    /// The files a warning backup couldn't read, for the row's "Show…" (Task 16b); nil for any other run and for records
    /// written before the items were kept.
    public var unreadable: UnreadableSummary?
    /// A backup's biggest additions, for the line under its detail and its "Show…" (Task 16d); nil for any other run,
    /// for a backup whose files added nothing, and for records written before they were kept. Information only.
    public var biggestAdditions: BiggestAdditionsSummary?
}

/// A "Show…" link on a History row (Task 16d review m2): one per sheet, and worded apart when a row has both.
public struct HistoryLink: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// "Files that couldn't be read" (Task 16b).
        case unreadable
        /// "Biggest additions" (Task 16d).
        case biggestAdditions
    }

    public var kind: Kind
    public var title: String
    public var accessibilityLabel: String
    public var id: String { "\(kind)" }

    /// The row's context-menu item for the same sheet: always the specific name, since a menu lists it with the others
    /// (Task 17c).
    public var menuTitle: String {
        switch kind {
        case .unreadable: "Show Unreadable Files…"
        case .biggestAdditions: "Show Biggest Additions…"
        }
    }
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
        case .notRun: "Skipped and Paused"
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
            details.append("\(unreadable) \(unreadable == 1 ? "file" : "files") couldn’t be read")
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
                outcome = "Couldn’t remove earlier snapshots"
            } else {
                outcome = "\(operationTitle(record.operation)) failed"
            }
            if let reason = record.outcome.failureReason { details.append(reason) }
            kind = .failure
        }
        let note = details.isEmpty ? nil : details.joined(separator: " · ")
        var addedBytes: Int64?
        var added: String?
        if let summary = record.summary, record.operation == .backup {
            addedBytes = Int64(summary.dataAdded)
            added = DisplayFormat.size(Int64(summary.dataAdded), locale: locale)
        }
        let seconds = duration(record)
        let durationText = seconds.map { DisplayFormat.duration(seconds: $0) }
        details += [added, durationText].compactMap { $0 }
        return HistoryRow(
            id: record.id, planID: record.planID, endedAt: record.endedAt,
            time: time(record.endedAt, now: now, calendar: calendar, locale: locale),
            plan: planNames[record.planID] ?? "Deleted plan", operation: operationTitle(record.operation),
            outcome: outcome, detail: details.isEmpty ? nil : details.joined(separator: " · "), note: note,
            added: added, addedBytes: addedBytes, duration: durationText, durationSeconds: seconds, kind: kind,
            logFile: record.logFile.isEmpty ? nil : record.logFile, unreadable: UnreadableSummary(record: record),
            biggestAdditions: BiggestAdditionsText.summary(record: record, locale: locale))
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

    /// The row's "Show…" links, in order. The couldn't-read one only where `offersUnreadable` (a plan's own list, which
    /// has an editor to add exclusions to); the biggest-additions one in every list. A row with both names each
    /// ("Show Unreadable Files…", "Show Biggest Additions…"), so two identical links never sit side by side.
    public static func links(for row: HistoryRow, offersUnreadable: Bool) -> [HistoryLink] {
        let unreadable = offersUnreadable && row.unreadable != nil
        let additions = row.biggestAdditions != nil
        let both = unreadable && additions
        var links: [HistoryLink] = []
        if unreadable {
            links.append(HistoryLink(
                kind: .unreadable, title: both ? "Show Unreadable Files…" : "Show…",
                accessibilityLabel: "Show the files that couldn’t be read"))
        }
        if additions {
            links.append(HistoryLink(
                kind: .biggestAdditions, title: both ? "Show Biggest Additions…" : "Show…",
                accessibilityLabel: "Show the biggest additions"))
        }
        return links
    }

    /// What a row's "Copy Outcome" puts on the pasteboard (Task 17e, audit T4): how the run ended and what belongs with
    /// it, as the Outcome column shows them ("Backup failed · wrong password").
    public static func outcomeText(_ row: HistoryRow) -> String {
        ([row.outcome] + [row.note].compactMap(\.self)).joined(separator: " · ")
    }

    /// What Copy (⌘C) puts on the pasteboard for the selected rows: one line per run, in the list's order, with every
    /// column the list has ("Yesterday, 09:05 · Home · Backup · Backed up · 1.2 GB · 3 min").
    public static func copyText(_ rows: [HistoryRow]) -> String {
        rows.map { row in
            ([row.time, row.plan, row.operation, row.outcome] + [row.detail].compactMap(\.self)).joined(separator: " · ")
        }
        .joined(separator: "\n")
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
