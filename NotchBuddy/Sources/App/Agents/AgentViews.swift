#if !APPSTORE
import SwiftUI

// MARK: - Agent cards (overview left card when one of the two pills is focused)
// Display only: a click opens a fixed web address or shows a folder. Names are verbatim.

struct AgentPillCardView: View {
    let task: AgentTask

    var body: some View {
        if task.id == AgentPills.usageReset {
            UsageResetCardView(task: task)
        } else {
            ClaudeJobsCardView(task: task)
        }
    }
}

// MARK: - Usage reset

private struct UsageResetCardView: View {
    let task: AgentTask
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        DevFlowCard(task: task) {
            if let reset = store.reset {
                Button { AgentActions.openUsagePage() } label: { countdown(reset) }
                    .buttonStyle(.plain)
                    .help(String(localized: "agents.reset.open"))
            } else {
                DevFlowNote(text: String(localized: "Loading…"))
            }
        }
        .onAppear { UsageResetWatcher.shared.refresh() }
    }

    private func countdown(_ reset: UsageResetInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                let left = DurationParts.of(reset.resetsAt.timeIntervalSinceNow, roundUp: true).text
                Text(verbatim: String(format: String(localized: "agents.reset.in %@"), left))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                if reset.isEstimate {
                    Text(verbatim: String(localized: "agents.reset.estimate"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#F5A524"))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(hex: "#F5A524").opacity(0.14))
                        .clipShape(Capsule())
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(hex: "#5F646D"))
                Spacer(minLength: 0)
            }
            Text(verbatim: detail(reset))
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
            DevFlowNote(text: note(reset))
        }
        .contentShape(Rectangle())
    }

    private func detail(_ reset: UsageResetInfo) -> String {
        switch reset.source {
        case .claudeCode(.fiveHour, let used):
            return String(format: String(localized: "agents.reset.five-hour %lld"), Int64(used.rounded()))
        case .claudeCode(.week, let used):
            return String(format: String(localized: "agents.reset.weekly %lld"), Int64(used.rounded()))
        case .estimate:
            return String(format: String(localized: "agents.reset.daily %@"), AgentSettings.resetTime.text)
        }
    }

    /// The clock time it resets at, with the week's use beside the 5-hour window; for an
    /// estimate, why there is nothing better.
    private func note(_ reset: UsageResetInfo) -> String {
        if reset.isEstimate {
            return appState.planRelayInstalled ? String(localized: "agents.reset.waiting")
                                               : String(localized: "agents.reset.no-relay")
        }
        let far = reset.resetsAt.timeIntervalSinceNow >= 20 * 3600
        let time = far ? reset.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                       : reset.resetsAt.formatted(date: .omitted, time: .shortened)
        var parts = [String(format: String(localized: "agents.reset.at %@"), time)]
        if case .claudeCode(.fiveHour, _) = reset.source,
           let week = appState.claudePlanUsage?.sevenDay, week.resetsAt > Date() {
            parts.append(String(format: String(localized: "agents.reset.week-used %lld"),
                                Int64(week.usedPct.rounded())))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Claude jobs

private struct ClaudeJobsCardView: View {
    let task: AgentTask
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var appState = AppState.shared

    private var onScreen: Bool {
        appState.mode == .expanded && appState.view == .overview && appState.focusId == task.id
    }

    var body: some View {
        DevFlowCard(task: task) {
            if !store.jobsLoaded {
                DevFlowNote(text: String(localized: "Loading…"))
            } else if store.jobs.isEmpty && store.finishedJobs.isEmpty {
                DevFlowNote(text: String(localized: "agents.jobs.empty"))
            } else {
                // The elapsed times move on while the card is on screen.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(store.jobs) { job in
                                row(folder: job.folder, path: job.path, dot: "#22C55E",
                                    detail: DurationParts.of(context.date.timeIntervalSince(job.startedAt)).text)
                            }
                            ForEach(store.finishedJobs) { job in
                                row(folder: job.folder, path: job.path, dot: "#6B7079",
                                    detail: String(format: String(localized: "agents.jobs.finished-after %@"),
                                                   DurationParts.of(job.duration).text))
                            }
                        }
                    }
                }
            }
        }
        .onAppear { seen() }
        .onChange(of: onScreen) { _, _ in seen() }
    }

    private func seen() {
        if onScreen { AgentsController.shared.syncPills() }
    }

    private func row(folder: String, path: String, dot: String, detail: String) -> some View {
        Button { AgentActions.reveal(path) } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: dot))
                    .frame(width: 5, height: 5)
                Text(verbatim: folder.isEmpty ? String(localized: "agents.jobs.unknown-folder") : folder)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
    }
}

// MARK: - Notice (the finished card, for a finished job or a waiting Cursor agent)

/// The "finished" view: an agent notice of the focused pill, else the usual finished card.
struct AgentFinishedSlot: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let notice = state.agentNotice, state.focusId == notice.pillId {
            AgentNoticeView(state: state, notice: notice)
        } else {
            FinishedView(state: state)
        }
    }
}

/// Laid out like FinishedView. A click anywhere but OK does what the first button does.
private struct AgentNoticeView: View {
    @ObservedObject var state: AppState
    let notice: AgentNotice

    private var wash: CardBackground<EmptyView>.Wash {
        notice.kind == .jobFinished ? .green : .amber
    }

    private var label: String {
        notice.kind == .jobFinished ? "agents.notice.job" : "agents.notice.cursor"
    }

    private var button: String {
        notice.kind == .jobFinished ? "agents.notice.show-folder" : "agents.notice.open-cursor"
    }

    var body: some View {
        ZStack {
            CardBackground(wash: wash)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    AgentWho(task: state.focusTask, label: label)
                    if notice.count > 1 {
                        Text(verbatim: "+\(notice.count - 1)")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                }
                Text(verbatim: notice.text)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if notice.kind == .cursorNeedsInput || notice.folderPath != nil {
                        PrimaryButton(button) { open() }
                    }
                    SecondaryButton("OK") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { open() }
    }

    private func open() {
        switch notice.kind {
        case .jobFinished:      AgentActions.reveal(notice.folderPath ?? "")
        case .cursorNeedsInput: AgentActions.openCursor()
        }
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }
}
#endif
