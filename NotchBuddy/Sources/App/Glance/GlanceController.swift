#if !APPSTORE
import AppKit
import Combine

/// What stands beside the closed notch now. In memory only.
@MainActor
final class GlanceStore: ObservableObject {
    static let shared = GlanceStore()

    @Published var items: [GlanceItem] = []
    /// The item under the pointer: its line of detail shows
    @Published var hovered: GlanceKind?
    /// Where the views put each item, in the island panel's coordinates (y down): the clicks
    /// the panel takes.
    var frames: [GlanceKind: CGRect] = [:]

    private init() {}

    /// The shown item under `point` (panel coordinates, y down).
    func item(at point: CGPoint) -> GlanceItem? {
        items.first { frames[$0.kind]?.contains(point) == true }
    }
}

/// Gathers what the other features already know into the notch glance. It reads no source of
/// its own and has no polling timer: it looks again when one of them changes, on the meeting
/// watcher's own tick, and once when a time it counts down to comes. With every item turned
/// off, nothing is watched at all.
@MainActor
final class GlanceController {
    static let shared = GlanceController()

    private var subscriptions: Set<AnyCancellable> = []
    private var grokActivation: NSObjectProtocol?
    private var deadline: DispatchWorkItem?
    private var isOn = false
    private var refreshQueued = false

    private init() {}

    /// Called at launch and whenever a glance setting changes.
    func apply() {
        let on = !GlanceSettings.enabled(.standard).isEmpty
        if on != isOn {
            isOn = on
            if on { watch() } else { stop() }
        }
        // A Jira item just turned on shouldn't wait for the repository's next read.
        if GlanceSettings.isOn(.jira) { RepoWatcher.shared.refreshIfStale(maxAge: 60) }
        refresh()
    }

    private func watch() {
        let state = AppState.shared
        // Nothing was watching: what arrived meanwhile may have been read since.
        state.setIfChanged(\.grokBotUnread, false)
        let changes: [AnyPublisher<Void, Never>] = [
            state.$tasks.map { $0.map(\.id) }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            state.$grokBotPending.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            state.$grokBotUnread.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            state.$claudePlanUsage.map { _ in }.eraseToAnyPublisher(),
            DevFlowStore.shared.objectWillChange.eraseToAnyPublisher(),
            DayStore.shared.$meeting.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            BadgeStore.shared.$badges.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            // Do not disturb
            EdgeLightSettings.shared.objectWillChange.eraseToAnyPublisher(),
        ]
        // Publishers speak before the value is stored: looked at on the next turn, once.
        Publishers.MergeMany(changes)
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &subscriptions)
        // The Grok Bot card looked at: its new message is read.
        state.$mode.combineLatest(state.$view, state.$focusId)
            .receive(on: DispatchQueue.main)
            .sink { mode, view, focus in
                if mode == .expanded && view == .overview && focus == Glance.grokPillId {
                    AppState.shared.setIfChanged(\.grokBotUnread, false)
                }
            }
            .store(in: &subscriptions)
        grokActivation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == grokBotBundleId else { return }
            MainActor.assumeIsolated { AppState.shared.setIfChanged(\.grokBotUnread, false) }
        }
    }

    private func stop() {
        subscriptions = []
        if let grokActivation { NSWorkspace.shared.notificationCenter.removeObserver(grokActivation) }
        grokActivation = nil
        deadline?.cancel()
        deadline = nil
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    func refresh() {
        let store = GlanceStore.shared
        guard isOn else {
            publish([], in: store)
            return
        }
        let enabled = GlanceSettings.enabled(.standard)
        let now = Date()
        let state = AppState.shared
        let dev = DevFlowStore.shared
        var input = GlanceInputs()
        input.pills = Set(state.tasks.map(\.id))
        input.myPRs = dev.myPRs
        input.reviewCount = dev.reviews.count
        input.jiraKey = dev.jiraKey
        if case .issue(let issue) = dev.jira { input.jiraIssue = issue }
        input.meeting = DayStore.shared.meeting
        if enabled.contains(.usage) {
            input.usage = UsageReset.compute(usage: state.claudePlanUsage, daily: AgentSettings.resetTime,
                                             now: now, calendar: .current)
        }
        input.grokApprovals = state.grokBotPending.filter { $0.kind == .approval }.count
        input.grokQuestions = state.grokBotPending.count - input.grokApprovals
        input.grokUnread = state.grokBotUnread
        input.slack = BadgeStore.shared.badge(.slack)

        let shown = Glance.select(Glance.items(input, now: now), enabled: enabled,
                                  max: GlanceSettings.maxItems(.standard),
                                  doNotDisturb: EdgeLightSettings.shared.doNotDisturb)
        publish(shown, in: store)
        schedule(after: input, now: now, enabled: enabled)
    }

    private func publish(_ items: [GlanceItem], in store: GlanceStore) {
        guard store.items != items else { return }
        store.items = items
        let kinds = Set(items.map(\.kind))
        store.frames = store.frames.filter { kinds.contains($0.key) }
        if let hovered = store.hovered, !kinds.contains(hovered) { store.hovered = nil }
    }

    /// One shot, for what changes with time alone and has no tick of its own: the usage
    /// window reaching its reset. (The meeting's minutes follow MeetingWatcher's tick.)
    private func schedule(after input: GlanceInputs, now: Date, enabled: Set<GlanceKind>) {
        deadline?.cancel()
        deadline = nil
        guard enabled.contains(.usage), let info = input.usage, !info.isEstimate else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        deadline = item
        // Wall clock: it counts the time the Mac sleeps.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(1, info.resetsAt.timeIntervalSince(now) + 1),
                                      execute: item)
    }
}

extension Notification.Name {
    /// A glance item was clicked; the object is its pill's id.
    static let glanceOpen = Notification.Name("notchBuddy.glanceOpen")
}
#endif
