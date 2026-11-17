import AppKit
import RestoreyCore
import SwiftUI

/// The runs, newest first (UI design §6.4, mockup `v0.1-settings.html`): time, plan, step, how it ended in the
/// menu's wording, what it added and how long it took, and its log. `planID` fixes the list to one plan (a plan's
/// History tab); nil lists every plan with a plan filter. The rows are `HistoryPresentation`'s.
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
    /// The plan's editor in a plan's own History tab, where "Show…" can add an exclusion to it (Task 16b); nil in the
    /// all-plans list, which has no editor, so it offers no "Show…".
    let editor: PlanEditModel?
    @State private var unreadable: UnreadableShown?

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
                        Text("All plans").tag(UUID?.none)
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
            List(rows) { row in
                HistoryRowView(
                    row: row, showsPlan: planID == nil, showLog: { open(row) }, showUnreadable: unreadableAction(row))
            }
            .listStyle(.bordered)
            .overlay {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).padding()
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
        .alert("This run's log is no longer there.", isPresented: $missingLog) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Run logs are kept for 400 days, and go with their plan when it is deleted.")
        }
    }

    /// "Show…" for a warning's unreadable files, where there is an editor to add an exclusion to.
    private func unreadableAction(_ row: HistoryRow) -> (() -> Void)? {
        guard editor != nil, let summary = row.unreadable else { return nil }
        return { unreadable = UnreadableShown(id: row.id, summary: summary) }
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
        guard let file = row.logFile,
            let url = HistoryPresentation.logURL(file, logsDirectory: supervisor.identity.logsDirectory())
        else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            missingLog = true
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct HistoryRowView: View {
    let row: HistoryRow
    let showsPlan: Bool
    let showLog: () -> Void
    /// "Show…" for the files a warning backup couldn't read; nil when there are none to show.
    let showUnreadable: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(colour)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(row.time)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)
            if showsPlan {
                Text(row.plan).lineLimit(1).frame(minWidth: 120, alignment: .leading)
            }
            Text(row.operation)
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.outcome)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let showUnreadable {
                Button("Show…", action: showUnreadable)
                    .buttonStyle(.link)
                    .accessibilityLabel("Show the files that couldn't be read")
            }
            if row.logFile != nil {
                Button("Show Log", action: showLog)
                    .buttonStyle(.link)
            }
        }
    }

    private var colour: Color {
        switch row.kind {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .skipped: .secondary
        }
    }
}
