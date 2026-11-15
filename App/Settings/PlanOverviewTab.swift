import RestoreyCore
import SwiftUI

/// Settings → Plans → Overview (Task 14c, owner 15 Nov 2026): the menu's line for the plan, its last and next backup,
/// and the menu's Back Up Now, Pause, Resume and Restore Files… for it. The words and which buttons are enabled are
/// `MenuPresentation.overview`'s, from the same inputs as the menu, so it follows the agent live, progress included.
struct PlanOverviewTab: View {
    let planID: UUID
    let context: SettingsContext

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
            notificationsAuthorised: supervisor.lastHello?.notificationsAuthorised, rates: supervisor.rates.bytesPerSecond,
            now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }

    @ViewBuilder private func content(_ overview: PlanOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(overview.status)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColour(overview))
                if let detail = overview.statusDetail {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let progress = overview.progress {
                    ProgressView(value: progress).accessibilityLabel("Backup progress")
                }
                if let destination = overview.destination {
                    Text(destination).font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Last backup", overview.lastBackup, overview.lastBackupDetail)
                if let next = overview.nextBackup {
                    row("Next backup", next, overview.nextBackupDetail)
                }
            }

            HStack {
                ForEach(overview.buttons, id: \.kind) { button in
                    Button(button.title) { perform(button.kind) }
                        .disabled(!button.enabled)
                        .accessibilityLabel(button.title)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, _ detail: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusColour(_ overview: PlanOverview) -> Color {
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
