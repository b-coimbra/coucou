#if !APPSTORE
import AppKit
import Combine

/// What the agent pills' cards show. In memory only.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()
    static let keptFinishedJobs = 5

    @Published var reset: UsageResetInfo?
    @Published var jobs: [ClaudeJob] = []
    @Published var jobsLoaded = false
    /// Newest first, the last few only
    @Published var finishedJobs: [FinishedClaudeJob] = []
    /// A job finished and its card hasn't been on screen since
    @Published var jobsUnseen = false

    private init() {}

    /// A @Published set redraws every card, even with the same value.
    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AgentStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// Starts and stops the agent features with the settings: nothing runs for one that is off.
@MainActor
final class AgentsController {
    static let shared = AgentsController()
    private var subscriptions: Set<AnyCancellable> = []
    private var wasExpanded = false

    private init() {}

    /// Called once at launch.
    func start() {
        guard subscriptions.isEmpty else { return }
        AppState.shared.$activeIntegrations
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)
        AppState.shared.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.modeChanged(mode) }
            .store(in: &subscriptions)
        apply()
    }

    /// Brings the watchers in line with the settings. Safe to call at any time.
    func apply() {
        let active = AppState.shared.activeIntegrations
        UsageResetWatcher.shared.configure(active.contains(AgentPills.usageReset))
        ClaudeJobWatcher.shared.configure(active.contains(AgentPills.claudeJobs))
        if !AgentSettings.cursorPing { CursorPingController.shared.stop() }
        syncPills()
    }

    private func modeChanged(_ mode: IslandMode) {
        // A notice whose card was closed has been said.
        if wasExpanded && mode != .expanded { AppState.shared.agentNotice = nil }
        wasExpanded = mode == .expanded
        UsageResetWatcher.shared.visibilityChanged()
    }

    /// The pills' names (countdown, job count) and the dot of the jobs pill.
    func syncPills() {
        let state = AppState.shared
        let store = AgentStore.shared
        for id in AgentPills.all {
            guard let i = state.tasks.firstIndex(where: { $0.id == id }),
                  let name = PillCatalog.definition(for: id)?.name else { continue }
            var shown = name
            if id == AgentPills.usageReset, let reset = store.reset {
                let left = DurationParts.of(reset.resetsAt.timeIntervalSinceNow, roundUp: true).text
                // "~" marks an estimate; the card says so in words.
                shown = reset.isEstimate ? "~\(left)" : left
            } else if id == AgentPills.claudeJobs, !store.jobs.isEmpty {
                shown = "\(name) \(store.jobs.count)"
            }
            if state.tasks[i].name != shown { state.tasks[i].name = shown }
        }
        syncAttentionDot()
    }

    /// The dot stays while a finished job's card hasn't been on screen. Checked after every
    /// look, because focusing the pill removes badges.
    private func syncAttentionDot() {
        let state = AppState.shared
        let store = AgentStore.shared
        let id = AgentPills.claudeJobs
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        if state.mode == .expanded && state.view == .overview && state.focusId == id {
            store.setIfChanged(\.jobsUnseen, false)
        }
        if store.jobsUnseen {
            if state.tasks[i].pillBadge != .approval { state.tasks[i].pillBadge = .approval }
        } else if state.tasks[i].pillBadge == .approval {
            state.tasks[i].pillBadge = nil
        }
    }
}

/// The notch notice of the agent features, shown on the "finished" card.
@MainActor
enum AgentNotices {
    /// Counts the notices, so an older auto-clear leaves a newer one alone
    private static var shown = 0

    /// false, and nothing happens, while the user is busy in a card.
    static func present(_ notice: AgentNotice) -> Bool {
        let state = AppState.shared
        // Set first: the card reads it as soon as the island opens
        state.agentNotice = notice
        guard HookServer.shared.presentNotice(pill: notice.pillId) else {
            state.agentNotice = nil
            return false
        }
        if let i = state.tasks.firstIndex(where: { $0.id == notice.pillId }) {
            state.tasks[i].pillBadge = nil
        }
        self.shown += 1
        let current = self.shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard AgentNotices.shown == current else { return }
            AgentNotices.dismiss(pill: notice.pillId)
        }
        return true
    }

    /// Forgets the pill's notice. If its card is on screen, the overview takes its place.
    static func dismiss(pill: String) {
        let state = AppState.shared
        guard state.agentNotice?.pillId == pill else { return }
        if state.mode == .expanded && state.view == .finished && state.focusId == pill {
            state.view = .overview
        }
        state.agentNotice = nil
    }
}

/// What a click does: opens a fixed web address or an app, or shows a folder in the Finder.
@MainActor
enum AgentActions {
    static let usagePage = "https://claude.ai/settings/usage"

    static func openPill(_ id: String) {
        if id == AgentPills.usageReset {
            openUsagePage()
        } else {
            TerminalTarget.activate(sessionBundleId: nil)
        }
    }

    static func openUsagePage() {
        if let url = URL(string: usagePage) { NSWorkspace.shared.open(url) }
    }

    /// Revealed, never opened: a folder is not launched whatever its name.
    static func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    static func openCursor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CursorPingController.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }
}

extension DurationParts {
    var text: String {
        switch self {
        case .underMinute:
            return String(localized: "agents.duration.under-minute")
        case .minutes(let m):
            return String(format: String(localized: "agents.duration.minutes %lld"), Int64(m))
        case .hours(let h, let m):
            return String(format: String(localized: "agents.duration.hours %lld %lld"), Int64(h), Int64(m))
        case .days(let d, let h):
            return String(format: String(localized: "agents.duration.days %lld %lld"), Int64(d), Int64(h))
        }
    }
}
#endif
