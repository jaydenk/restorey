import RestoreyCore
import SwiftUI

/// Settings → Plans → Overview (Task 14c, owner 15 Nov 2026; layout ruling R1): the plan's state with the menu's reason,
/// its last and next backup, and the menu's Back Up Now, Pause, Resume and Restore Files… for it. The words and which
/// buttons are enabled are `MenuPresentation.overview`'s, from the same inputs as the menu, so it follows the agent
/// live, progress included.
struct PlanOverviewTab: View {
    let planID: UUID
    let context: SettingsContext
    /// The plan's editor, so the unreadable-files sheet can add an exclusion to it (Task 16b).
    let model: PlanEditModel
    @State private var showingUnreadable = false

    private var supervisor: AgentSupervisor { context.supervisor }

    var body: some View {
        // Times like "Next 15:16" and "yesterday at" move on even when nothing new arrives from the agent.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if let overview = overview(now: timeline.date) {
                content(overview)
            }
        }
    }

    private func overview(now: Date) -> PlanOverview? {
        MenuPresentation.overview(
            planID: planID, health: supervisor.health,
            status: menuStatus(health: supervisor.health, live: supervisor.status, lastKnown: supervisor.lastKnownStatus),
            notificationsAuthorised: supervisor.lastHello?.notificationsAuthorised,
            now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }

    @ViewBuilder private func content(_ overview: PlanOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The plan's state and the menu's reason; no plan name or repository here (the title has the name), and
            // no times (the rows have them).
            VStack(alignment: .leading, spacing: 4) {
                Text(overview.headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(headlineColour(overview))
                if let reason = overview.reason {
                    Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if overview.unreadable != nil {
                    Button("Show…") { showingUnreadable = true }
                        .buttonStyle(.link)
                        .accessibilityLabel("Show the files that couldn't be read")
                }
                if let progress = overview.progress {
                    ProgressView(value: progress).accessibilityLabel("Backup progress")
                }
            }
            .accessibilityElement(children: .combine)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if let last = overview.lastBackup { row("Last backup", last) }
                if let next = overview.nextBackup { row("Next backup", next) }
            }

            if let note = overview.cloudOnlyNote { CloudOnlyNoteView(note: note) }
            if let note = overview.earlierRemovalNote {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                ForEach(overview.buttons, id: \.kind) { button in
                    Button(button.title) { perform(button.kind) }
                        .disabled(!button.enabled)
                }
            }
        }
        .sheet(isPresented: $showingUnreadable) {
            if let unreadable = overview.unreadable { UnreadableFilesSheet(summary: unreadable, model: model) }
        }
    }

    private func row(_ label: String, _ row: PlanOverview.Row) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.value)
                if let detail = row.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Coloured only when the plan needs attention, and then the reason (or the headline itself) says why.
    private func headlineColour(_ overview: PlanOverview) -> Color {
        if overview.isPaused { return .secondary }
        switch overview.severity {
        case .error?: return .red
        case .warning?: return .orange
        case nil: return .primary
        }
    }

    /// What the menu's items do, through the same calls (`AgentActions`) and router.
    private func perform(_ kind: PlanOverview.Button.Kind) {
        let connection = supervisor.connection
        switch kind {
        case .backUpNow: AgentActions.backUpNow(planID, connection)
        case .pause: AgentActions.pause([planID], connection)
        case .resume: AgentActions.resume([planID], connection)
        case .restoreFiles: context.showRestoreFiles(planID)
        }
    }
}

/// "iCloud Drive files skipped" with an info button whose popover says why and how to include them. Quiet: secondary
/// text, no colour.
private struct CloudOnlyNoteView: View {
    let note: PlanOverview.CloudOnlyNote
    @State private var showsDetail = false

    var body: some View {
        HStack(spacing: 4) {
            Text(note.line).font(.callout).foregroundStyle(.secondary)
            Button { showsDetail.toggle() } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(note.accessibilityLabel)
            .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
                Text(note.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding()
            }
        }
    }
}
