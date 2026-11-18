import AppKit
import RestoreyCore
import SwiftUI

/// The runs, newest first (UI design §6.4, mockup `v0.1-settings.html`), as a table (Task 17c, P11; HIG Lists and
/// tables: sortable, resizable columns): time, plan, step, how it ended in the menu's wording, what it added and how
/// long it took. A row's log opens with a double-click, its "Show Log" link or its context menu, which also has Show Log
/// in Finder, Copy Outcome and the row's "Show…" sheets; ⌘C copies the selected rows (Task 17e). `planID` fixes the
/// list to one plan (a plan's History tab); nil lists every plan with a plan filter. The rows are `HistoryPresentation`'s.
///
/// The records come from the agent's `history` call, fetched again whenever a plan's newest record changes, so a
/// run that ends while the list is open appears in it. Reads the supervisor from the environment.
struct HistoryList: View {
    let planID: UUID?
    @Environment(AgentSupervisor.self) private var supervisor
    @State private var records: [RunRecord] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var planFilter: UUID?
    @State private var filter: HistoryFilter = .everything
    @State private var missingLog = false
    /// The plan's editor in a plan's own History tab, where the couldn't-read "Show…" can add an exclusion to it (Task
    /// 16b); nil in the all-plans list, which has no editor, so it offers that one no "Show…". The biggest-additions
    /// "Show…" changes nothing, so every list offers it (Task 16d).
    let editor: PlanEditModel?
    @State private var unreadable: UnreadableShown?
    @State private var additions: AdditionsShown?
    @State private var selection: Set<HistoryRow.ID> = []
    /// Newest first until a column heading is clicked.
    @State private var sortOrder = [KeyPathComparator(\HistoryRow.endedAt, order: .reverse)]

    private struct AdditionsShown: Identifiable {
        let id: UUID
        let additions: BiggestAdditions
    }

    private struct UnreadableShown: Identifiable {
        let id: UUID
        let summary: UnreadableSummary
    }

    /// The all-plans list's requested filter (the menu's "Show Details…"), applied when the list appears and
    /// again whenever a new request arrives while it is open.
    let filterRequest: HistoryFilterRequest?

    init(planID: UUID?, filterRequest: HistoryFilterRequest? = nil, editor: PlanEditModel? = nil) {
        self.planID = planID
        self.editor = editor
        self.filterRequest = filterRequest
        _planFilter = State(initialValue: planID == nil ? filterRequest?.planID : nil)
    }

    private var plans: [Plan] { supervisor.lastKnownStatus?.plans.map(\.plan) ?? [] }

    /// Changes when any plan records a new run.
    private var newestRecords: [UUID?] { supervisor.lastKnownStatus?.plans.map { $0.lastRecord?.id } ?? [] }

    var body: some View {
        let rows = HistoryPresentation.rows(
            records, plan: planID ?? planFilter, filter: filter,
            planNames: Dictionary(plans.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            now: Date(), calendar: .current, locale: .current)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if planID == nil {
                    Picker("Plan", selection: $planFilter) {
                        Text("All Plans").tag(UUID?.none)
                        ForEach(plans) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .fixedSize()
                    // VoiceOver otherwise names the pop-up by its value ("All plans") (live finding 4).
                    .accessibilityLabel("Plan")
                }
                Picker("Show", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .accessibilityLabel("Show")
                Spacer()
            }
            table(rows.sorted(using: sortOrder))
            .overlay {
                if let loadError {
                    SeverityText(loadError, font: .body).padding()
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else if rows.isEmpty {
                    Text(records.isEmpty ? "No runs yet" : "No runs match").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: newestRecords) { await load() }
        .onChange(of: filterRequest) { if planID == nil { planFilter = filterRequest?.planID } }
        .sheet(item: $unreadable) { shown in
            if let editor { UnreadableFilesSheet(summary: shown.summary, model: editor) }
        }
        .sheet(item: $additions) { BiggestAdditionsSheet(additions: $0.additions) }
        .alert("This run’s log is no longer there.", isPresented: $missingLog) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Run logs are kept for 400 days, and go with their plan when it is deleted.")
        }
    }

    private func links(_ row: HistoryRow) -> [HistoryLink] {
        HistoryPresentation.links(for: row, offersUnreadable: editor != nil)
    }

    private func table(_ rows: [HistoryRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.endedAt) { row in
                Text(row.time).monospacedDigit()
            }
            .width(min: 100, ideal: 108, max: 120)
            if planID == nil {
                TableColumn("Plan", value: \.plan) { row in
                    Text(row.plan).lineLimit(1).help(row.plan)
                }
                .width(min: 70, ideal: 110, max: 130)
            }
            // A plan's own list has no Step column: its outcomes already say the step ("Backed up", "Old snapshots
            // tidied", "Check failed", "Skipped: …"), and the width goes to Outcome (review I2).
            if planID == nil {
                TableColumn("Step", value: \.operation) { row in
                    Text(row.operation)
                }
                .width(min: 52, ideal: 52, max: 64)
            }
            TableColumn("Outcome", value: \.outcome) { row in
                OutcomeCell(row: row, links: links(row), showLog: { open(row) }, show: { show($0, row) })
            }
            .width(min: 180, ideal: 200)
            TableColumn("Added", value: \.addedSortKey) { row in
                Text(row.added ?? "").monospacedDigit()
            }
            .width(min: 50, ideal: 56, max: 66)
            TableColumn("Duration", value: \.durationSortKey) { row in
                Text(row.duration ?? "").monospacedDigit()
            }
            .width(min: 50, ideal: 56, max: 66)
        }
        .contextMenu(forSelectionType: HistoryRow.ID.self) { ids in
            if let row = rows.first(where: { ids.count == 1 && ids.contains($0.id) }) {
                Button("Show Log") { open(row) }
                    .disabled(row.logFile == nil)
                Button("Show Log in Finder") { reveal(row) }
                    .disabled(row.logFile == nil)
                Button("Copy Outcome") { copy(HistoryPresentation.outcomeText(row)) }
                let links = links(row)
                if !links.isEmpty {
                    Divider()
                    ForEach(links) { link in
                        Button(link.menuTitle) { show(link.kind, row) }
                    }
                }
            }
        } primaryAction: { ids in
            // A double-click (or Return) on one row opens its log, as Finder opens a document.
            if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) { open(row) }
        }
        // Edit → Copy (⌘C): the selected rows as text, one line each, in the list's order (Task 17e, audit P11).
        .onCopyCommand {
            let selected = rows.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return [] }
            return [NSItemProvider(object: HistoryPresentation.copyText(selected) as NSString)]
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens the sheet behind one of the row's links (`HistoryPresentation.links`).
    private func show(_ kind: HistoryLink.Kind, _ row: HistoryRow) {
        switch kind {
        case .unreadable:
            if let summary = row.unreadable { unreadable = UnreadableShown(id: row.id, summary: summary) }
        case .biggestAdditions:
            if let summary = row.biggestAdditions { additions = AdditionsShown(id: row.id, additions: summary.additions) }
        }
    }

    private func load() async {
        switch await supervisor.connection.history(planID) {
        case .success(let fetched):
            records = fetched
            loadError = nil
        case .failure(let error):
            loadError = FormValidation.sentence(error.description)
        }
        loaded = true
    }

    private func open(_ row: HistoryRow) {
        guard let url = existingLog(row) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ row: HistoryRow) {
        guard let url = existingLog(row) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The row's log while it is still there; a log that has gone says so (`missingLog`).
    private func existingLog(_ row: HistoryRow) -> URL? {
        guard let file = row.logFile,
            let url = HistoryPresentation.logURL(file, logsDirectory: supervisor.identity.logsDirectory())
        else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            missingLog = true
            return nil
        }
        return url
    }
}

/// A row's Outcome cell: the outcome's symbol (its own shape, so it isn't carried by colour alone) and words, what
/// belongs with it, the biggest additions' line, and the row's links. The words and the reason wrap to the column's width
/// (with no `fixedSize`, which made the table size the row for one line and cut the rest; review I2), so a failure's
/// reason is read in full at any width; the additions line, a list of names, stays on one line with a help tag.
private struct OutcomeCell: View {
    let row: HistoryRow
    /// The row's "Show…" links, from `HistoryPresentation.links`.
    let links: [HistoryLink]
    let showLog: () -> Void
    let show: (HistoryLink.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: row.kind.symbolName)
                    .foregroundStyle(row.kind.tint)
                    .accessibilityLabel(row.kind.accessibilityLabel)
                Text(row.outcome).lineLimit(nil)
            }
            if let note = row.note {
                Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(nil)
            }
            if let additions = row.biggestAdditions {
                Text(additions.line).explanatoryNote().lineLimit(1).truncationMode(.tail).help(additions.line)
            }
            if !links.isEmpty || row.logFile != nil {
                HStack(spacing: 10) {
                    ForEach(links) { link in
                        Button(link.title) { show(link.kind) }
                            .accessibilityLabel(link.accessibilityLabel)
                    }
                    if row.logFile != nil {
                        Button("Show Log", action: showLog)
                    }
                }
                .buttonStyle(.link)
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HistoryRow {
    /// What the Added and Duration columns sort by: a row without one sorts before the smallest.
    var addedSortKey: Int64 { addedBytes ?? -1 }
    var durationSortKey: TimeInterval { durationSeconds ?? -1 }
}
