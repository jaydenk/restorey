import RestoreyCore
import SwiftUI

/// Settings → Plans → Overview (Task 14c, owner 15 Nov 2026; layout ruling R1; Task 17c): the plan's state with the
/// menu's reason and the menu's Back Up Now, Pause, Resume and Restore Files… for it, then its last and next backup. The words and which
/// buttons are enabled are `MenuPresentation.overview`'s, from the same inputs as the menu, so it follows the agent
/// live, progress included.
struct PlanOverviewTab: View {
    let planID: UUID
    let context: SettingsContext
    /// The plan's editor, so the unreadable-files sheet can add an exclusion to it (Task 16b).
    let model: PlanEditModel
    @State private var showingUnreadable = false
    @State private var showingAdditions = false

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

    /// A grouped form like every other tab (Task 17c, F13). The state, its reason and the actions come first, with Back
    /// Up Now the one prominent button (HIG Buttons: a prominent style for the most likely action) and Pause or Resume
    /// beside it; Restore Files…, a different task, stands apart at the leading end (P15). Then the times.
    @ViewBuilder private func content(_ overview: PlanOverview) -> some View {
        Form {
            Section {
                state(overview)
                actions(overview)
            }
            Section {
                if let last = overview.lastBackup { row("Last backup", last) }
                if let next = overview.nextBackup { row("Next backup", next) }
                if let additions = overview.biggestAdditions {
                    LabeledContent {
                        Button("Show…") { showingAdditions = true }
                            .accessibilityLabel("Show the biggest additions")
                    } label: {
                        Text(additions.line).explanatoryNote()
                    }
                }
                if let note = overview.cloudOnlyNote { CloudOnlyNoteView(note: note) }
                if let note = overview.earlierRemovalNote {
                    Text(note).explanatoryNote()
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingUnreadable) {
            if let unreadable = overview.unreadable { UnreadableFilesSheet(summary: unreadable, model: model) }
        }
        .sheet(isPresented: $showingAdditions) {
            if let additions = overview.biggestAdditions { BiggestAdditionsSheet(additions: additions.additions) }
        }
    }

    /// The plan's state and the menu's reason; no plan name or repository here (the title has the name), and no times
    /// (the rows have them).
    private func state(_ overview: PlanOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // A plan that needs attention has its symbol; the words stay in the label colour.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if overview.isPaused {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityLabel("Paused")
                } else if let severity = overview.severity {
                    SeverityIcon(severity: severity)
                }
                Text(overview.headline).foregroundStyle(overview.isPaused ? .secondary : .primary)
            }
            .font(.headline)
            if let reason = overview.reason {
                Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if overview.unreadable != nil {
                Button("Show…") { showingUnreadable = true }
                    .buttonStyle(.link)
                    .accessibilityLabel("Show the files that couldn’t be read")
            }
            if let progress = overview.progress {
                ProgressView(value: progress).accessibilityLabel("Backup progress")
            } else if overview.isChecking {
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Backup progress")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func actions(_ overview: PlanOverview) -> some View {
        let restore = overview.buttons.first { $0.kind == .restoreFiles }
        let backup = overview.buttons.filter { $0.kind != .restoreFiles }
        return HStack {
            if let restore { button(restore) }
            Spacer()
            // Pause or Resume, then Back Up Now at the trailing end, where the most likely action goes.
            ForEach(backup.reversed(), id: \.kind) { button($0) }
        }
    }

    @ViewBuilder private func button(_ button: PlanOverview.Button) -> some View {
        if button.kind == .pause {
            // A pull-down menu button: Pause is a choice of how long.
            Menu(button.title) {
                ForEach(PauseLength.allCases, id: \.self) { length in
                    Button(length.menuTitle) { AgentActions.pause([planID], for: length, supervisor.connection) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!button.enabled)
        } else if button.kind == .backUpNow {
            Button(button.title) { perform(button.kind) }
                .buttonStyle(.borderedProminent)
                .disabled(!button.enabled)
        } else {
            Button(button.title) { perform(button.kind) }
                .disabled(!button.enabled)
        }
    }

    private func row(_ label: String, _ row: PlanOverview.Row) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.value)
                if let detail = row.detail { Text(detail).explanatoryNote() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What the menu's items do, through the same calls (`AgentActions`) and router.
    private func perform(_ kind: PlanOverview.Button.Kind) {
        let connection = supervisor.connection
        switch kind {
        case .backUpNow: AgentActions.backUpNow(planID, connection)
        case .pause: break  // A menu of lengths, not a button: see `button(_:)`.
        case .cancel: AgentActions.cancel([planID], connection)
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
            Text(note.line).explanatoryNote()
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
