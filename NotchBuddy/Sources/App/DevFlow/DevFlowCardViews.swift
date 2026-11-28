#if !APPSTORE
import SwiftUI

// MARK: - Dev flow cards (overview left card when one of the four pills is focused)
// Display only: a click opens a web address built from structured fields, or an app.
// Fetched text is shown verbatim.

struct DevFlowCardView: View {
    let task: AgentTask

    var body: some View {
        switch task.id {
        case DevFlowPills.jira:         JiraCardView(task: task)
        case DevFlowPills.pullRequests: MyPRsCardView(task: task)
        case DevFlowPills.reviews:      ReviewsCardView(task: task)
        default:                        BranchCardView(task: task)
        }
    }
}

/// The header every card shares, and the room left for Mochi.
private struct DevFlowCard<Content: View>: View {
    let task: AgentTask
    /// What went wrong at the last read, shown as a warning beside the title.
    var warning: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: task.color))
                    .frame(width: 7, height: 7)
                // The catalog's name: the task's carries the key, the count or the branch.
                Text(verbatim: PillCatalog.definition(for: task.id)?.name ?? task.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                Text(verbatim: PillCatalog.definition(for: task.id)?.subtitle ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                if let warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#F5A524"))
                        .help(warning)
                        .accessibilityLabel(Text(warning))
                }
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            content
                .padding(.top, 5)
                .padding(.leading, 108)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

/// A line saying why there is nothing else to show.
private struct DevFlowNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#6B7079"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func ghMessage(_ failure: GHFailure?) -> String? {
    switch failure {
    case .missing?: return String(localized: "devflow.gh.missing")
    case .failed?:  return String(localized: "devflow.gh.failed")
    case nil:       return nil
    }
}

// MARK: - Jira card of the moment

private struct JiraCardView: View {
    let task: AgentTask
    @ObservedObject private var store = DevFlowStore.shared

    var body: some View {
        DevFlowCard(task: task) {
            if let key = store.jiraKey {
                Button { DevFlowActions.openJira() } label: { issue(key) }
                    .buttonStyle(.plain)
                    .help(String(localized: "devflow.jira.open"))
            } else if !store.repoLoaded {
                DevFlowNote(text: String(localized: "Loading…"))
            } else if let repo = store.repo {
                VStack(alignment: .leading, spacing: 3) {
                    DevFlowNote(text: String(format: String(localized: "devflow.jira.no-key %@"),
                                             DevFlowSettings.jiraPrefix))
                    DevFlowNote(text: "\(repo.name) · \(repo.branch)")
                }
            } else {
                DevFlowNote(text: String(localized: "devflow.repo.none"))
            }
        }
        .onAppear { RepoWatcher.shared.refreshIfStale() }
    }

    private func issue(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: key)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .fixedSize()
                if case .issue(let issue) = store.jira {
                    Text(verbatim: issue.status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: color(of: issue.category)))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(hex: color(of: issue.category)).opacity(0.14))
                        .clipShape(Capsule())
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(hex: "#5F646D"))
                Spacer(minLength: 0)
            }
            if case .issue(let issue) = store.jira {
                Text(verbatim: issue.summary)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else if let note {
                DevFlowNote(text: note)
            }
        }
        .contentShape(Rectangle())
    }

    private var note: String? {
        switch store.jira {
        case .noCredentials: return String(localized: "devflow.jira.no-credentials")
        case .badSite:       return String(localized: "devflow.jira.bad-url")
        case .loading:       return String(localized: "Loading…")
        case .unauthorized:  return String(localized: "devflow.jira.unauthorized")
        case .notFound:      return String(localized: "devflow.jira.not-found")
        case .unreachable:   return String(localized: "devflow.jira.unreachable")
        case .issue:         return nil
        }
    }

    private func color(of category: JiraIssue.Category) -> String {
        switch category {
        case .toDo, .unknown: return "#8E939C"
        case .inProgress:     return "#3B9EFF"
        case .done:           return "#22C55E"
        }
    }
}

// MARK: - My pull requests

private struct MyPRsCardView: View {
    let task: AgentTask
    @ObservedObject private var store = DevFlowStore.shared
    @ObservedObject private var appState = AppState.shared
    /// Rows with news shown since the card came on screen: seen once it leaves.
    @State private var shown: Set<String> = []

    private var onScreen: Bool {
        appState.mode == .expanded && appState.view == .overview && appState.focusId == task.id
    }

    var body: some View {
        DevFlowCard(task: task, warning: store.myPRsLoaded ? ghMessage(store.ghFailure) : nil) {
            if !store.myPRsLoaded {
                DevFlowNote(text: ghMessage(store.ghFailure) ?? String(localized: "Loading…"))
            } else if store.myPRs.isEmpty {
                DevFlowNote(text: String(localized: "devflow.prs.empty"))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.myPRs) { row($0) }
                    }
                }
            }
        }
        .onAppear {
            PRWatcher.shared.refreshIfStale()
            collect()
        }
        .onChange(of: onScreen) { _, now in
            if now {
                PRWatcher.shared.refreshIfStale()
                collect()
            } else {
                flush()
            }
        }
        .onChange(of: store.myPRs) { _, _ in collect() }
        .onDisappear { flush() }
    }

    private func collect() {
        guard onScreen else { return }
        shown.formUnion(store.myPRs.filter(\.unseen).map(\.id))
    }

    private func flush() {
        guard !shown.isEmpty else { return }
        let ids = shown
        shown = []
        PRWatcher.shared.markSeen(ids)
    }

    private func row(_ pr: PRRow) -> some View {
        let checks = pr.detail?.checks ?? .noChecks
        return Button {
            DevFlowActions.open(pr.summary.ref)
            PRWatcher.shared.markSeen([pr.id])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol(of: checks))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(hex: color(of: checks)))
                    .frame(width: 11)
                    .help(label(of: checks))
                    .accessibilityLabel(Text(label(of: checks)))
                Text(verbatim: pr.summary.ref.shortName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 82, alignment: .leading)
                    .layoutPriority(1)
                Text(verbatim: pr.summary.title)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let count = pr.detail?.activityCount, count > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 8))
                        Text(verbatim: "\(count)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                    .foregroundColor(Color(hex: "#8E939C"))
                    .fixedSize()
                    .help(String(format: String(localized: "devflow.prs.activity %lld"), Int64(count)))
                }
                if pr.unseen {
                    Circle()
                        .fill(Color(hex: "#F5A524"))
                        .frame(width: 5, height: 5)
                        .accessibilityLabel(Text("devflow.prs.new"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbol(of checks: PRCheckState) -> String {
        switch checks {
        case .passing:  return "checkmark.circle.fill"
        case .failing:  return "xmark.circle.fill"
        case .running:  return "clock.fill"
        case .noChecks: return "circle"
        }
    }

    private func color(of checks: PRCheckState) -> String {
        switch checks {
        case .passing:  return "#22C55E"
        case .failing:  return "#F4505E"
        case .running:  return "#F5A524"
        case .noChecks: return "#6B7079"
        }
    }

    private func label(of checks: PRCheckState) -> String {
        switch checks {
        case .passing:  return String(localized: "devflow.ci.passing")
        case .failing:  return String(localized: "devflow.ci.failing")
        case .running:  return String(localized: "devflow.ci.running")
        case .noChecks: return String(localized: "devflow.ci.none")
        }
    }
}

// MARK: - Review requests

private struct ReviewsCardView: View {
    let task: AgentTask
    @ObservedObject private var store = DevFlowStore.shared

    var body: some View {
        DevFlowCard(task: task, warning: store.reviewsLoaded ? ghMessage(store.ghFailure) : nil) {
            if !store.reviewsLoaded {
                DevFlowNote(text: ghMessage(store.ghFailure) ?? String(localized: "Loading…"))
            } else if store.reviews.isEmpty {
                DevFlowNote(text: String(localized: "devflow.reviews.empty"))
            } else {
                // Oldest first: the one waiting the longest is on top.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.reviews) { row($0) }
                    }
                }
            }
        }
        .onAppear { PRWatcher.shared.refreshIfStale() }
    }

    private func row(_ pr: PRSummary) -> some View {
        Button {
            DevFlowActions.open(pr.ref)
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: pr.ref.shortName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 82, alignment: .leading)
                    .layoutPriority(1)
                Text(verbatim: pr.title)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(verbatim: age(since: pr.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .monospacedDigit()
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pr.author.isEmpty ? pr.ref.id : "\(pr.ref.id) · \(pr.author)")
    }

    private func age(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

// MARK: - Branch glance

private struct BranchCardView: View {
    let task: AgentTask
    @ObservedObject private var store = DevFlowStore.shared

    var body: some View {
        DevFlowCard(task: task) {
            if let repo = store.repo {
                Button { DevFlowActions.openRepository() } label: { glance(repo) }
                    .buttonStyle(.plain)
                    .help(repo.path)
            } else {
                DevFlowNote(text: store.repoLoaded ? String(localized: "devflow.repo.none")
                                                   : String(localized: "Loading…"))
            }
        }
        .onAppear { RepoWatcher.shared.refreshIfStale() }
    }

    private func glance(_ repo: GitRepoSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: repo.name)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: task.color))
                Text(verbatim: repo.branch)
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if repo.detached {
                DevFlowNote(text: String(localized: "devflow.branch.detached"))
            }
            Text(verbatim: status(repo))
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1).truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    /// "Changed files: 3 · Ahead 1, behind 0"
    private func status(_ repo: GitRepoSnapshot) -> String {
        var parts: [String] = []
        switch repo.dirty {
        case 0?:        parts.append(String(localized: "devflow.branch.clean"))
        case let count?: parts.append(String(format: String(localized: "devflow.branch.changed %lld"), Int64(count)))
        case nil:       break
        }
        if let ahead = repo.ahead, let behind = repo.behind {
            parts.append(String(format: String(localized: "devflow.branch.distance %lld %lld"),
                                Int64(ahead), Int64(behind)))
        } else if !repo.detached {
            parts.append(String(localized: "devflow.branch.no-upstream"))
        }
        return parts.joined(separator: " · ")
    }
}
#endif
