#if !APPSTORE
import Combine
import Foundation

/// Keeps the countdown to the usage reset, while its pill is on. It only ticks while the
/// island is on screen, once a minute. No network, no file read.
@MainActor
final class UsageResetWatcher {
    static let shared = UsageResetWatcher()
    private var isOn = false
    private var usage: AnyCancellable?
    private var tick: Task<Void, Never>?

    private init() {}

    func configure(_ on: Bool) {
        guard on != isOn else {
            // The daily time may have changed.
            refresh()
            return
        }
        isOn = on
        guard on else {
            usage = nil
            tick?.cancel()
            tick = nil
            AgentStore.shared.setIfChanged(\.reset, nil)
            return
        }
        // What Claude Code's status line reports (ClaudePlanGauge).
        usage = AppState.shared.$claudePlanUsage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        visibilityChanged()
    }

    func visibilityChanged() {
        guard isOn else { return }
        guard AppState.shared.mode != .hidden else {
            tick?.cancel()
            tick = nil
            return
        }
        refresh()
        guard tick == nil else { return }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                // To the next minute, so the countdown changes with the clock.
                let wait = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                try? await Task.sleep(for: .seconds(wait + 0.2), tolerance: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard isOn else { return }
        let info = UsageReset.compute(usage: AppState.shared.claudePlanUsage, daily: AgentSettings.resetTime,
                                      now: Date(), calendar: .current)
        AgentStore.shared.setIfChanged(\.reset, info)
        AgentsController.shared.syncPills()
    }
}

/// Looks for headless `claude -p` runs every 10 seconds, while the jobs pill is on.
@MainActor
final class ClaudeJobWatcher {
    static let shared = ClaudeJobWatcher()
    private static let interval: TimeInterval = 10

    private let queue = DispatchQueue(label: "fr.louisraille.ClaudeJobWatcher", qos: .utility)
    private var loop: Task<Void, Never>?
    /// Changes with the configuration: a look started before it is dropped.
    private var generation = 0
    private var tracker = ClaudeJobTracker()

    private init() {}

    func configure(_ on: Bool) {
        guard on != (loop != nil) else { return }
        generation += 1
        loop?.cancel()
        loop = nil
        guard on else {
            tracker = ClaudeJobTracker()
            let store = AgentStore.shared
            store.setIfChanged(\.jobs, [])
            store.setIfChanged(\.jobsLoaded, false)
            store.setIfChanged(\.finishedJobs, [])
            store.setIfChanged(\.jobsUnseen, false)
            AgentNotices.dismiss(pill: AgentPills.claudeJobs)
            return
        }
        loop = Task { [weak self] in
            // Not in the way of the launch.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self?.look()
                try? await Task.sleep(for: .seconds(ClaudeJobWatcher.interval), tolerance: .seconds(2))
            }
        }
    }

    private func look() async {
        guard !DemoEngine.isPollerPaused else { return }
        let started = generation
        let queue = self.queue
        let found: [ClaudeJob]? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: ClaudeJobReader.jobs()) }
        }
        guard started == generation, let found else { return }
        apply(found)
    }

    private func apply(_ found: [ClaudeJob]) {
        let store = AgentStore.shared
        let finished = tracker.update(found, now: Date())
        store.setIfChanged(\.jobs, tracker.jobs)
        store.setIfChanged(\.jobsLoaded, true)
        guard let first = finished.first else {
            AgentsController.shared.syncPills()
            return
        }
        store.finishedJobs = Array((finished + store.finishedJobs).prefix(AgentStore.keptFinishedJobs))
        store.jobsUnseen = true
        SoundEngine.shared.play("finish")
        let folder = first.folder.isEmpty ? String(localized: "agents.jobs.unknown-folder") : first.folder
        let text = String(format: String(localized: "agents.jobs.finished-in %@ %@"),
                          folder, DurationParts.of(first.duration).text)
        // The dot is set whether or not the notice can be shown.
        _ = AgentNotices.present(AgentNotice(pillId: AgentPills.claudeJobs, kind: .jobFinished, text: text,
                                             count: finished.count,
                                             folderPath: first.path.isEmpty ? nil : first.path))
        AgentsController.shared.syncPills()
    }
}

/// An Edge Light pulse when a Cursor agent finishes or waits for the user, from the hook
/// events Coucou already receives. Adds a notice only where no card says it yet.
@MainActor
final class CursorPingController {
    static let shared = CursorPingController()
    static let pillId = "agent_cursor"
    static let bundleId = "com.todesktop.230313mzl4w4u92"

    private var detector = CursorPingDetector()
    /// The session whose question the notice (or the badge) stands for
    private var noticeSession: String?
    /// The pill's dot was set here, so it is ours to remove
    private var badged = false

    private init() {}

    /// A hook event of a Cursor session. Returns what it announced, nil for nothing or off.
    func event(_ name: String, session: String, payload: [String: Any]) -> CursorPing? {
        guard AgentSettings.cursorPing else {
            stop()
            return nil
        }
        let ping = detector.event(name, session: session,
                                  tool: payload["tool_name"] as? String ?? "",
                                  message: payload["message"] as? String ?? "",
                                  status: payload["status"] as? String ?? "",
                                  generation: payload["generation_id"] as? String ?? "")
        if noticeSession == session && !detector.isWaiting(session) { dismissNotice() }
        if let ping { pulse(ping) }
        return ping
    }

    /// A permission or question card of a Cursor session went up: the card is the notice.
    func requestShown(session: String) {
        guard AgentSettings.cursorPing else { return }
        pulse(detector.requestShown(session: session))
    }

    /// Nothing else says that Cursor's agent asked something: sound, then the notice, or the
    /// pill's dot while the user is busy in a card.
    func announceNeedsInput(session: String) {
        let state = AppState.shared
        guard let task = state.tasks.first(where: { $0.id == Self.pillId }) else { return }
        noticeSession = session
        SoundEngine.shared.play("question")
        let text = String(format: String(localized: "agents.cursor.waiting %@"), task.name)
        if !AgentNotices.present(AgentNotice(pillId: Self.pillId, kind: .cursorNeedsInput, text: text)) {
            state.setPillBadge(.approval, for: Self.pillId)
            badged = true
        }
    }

    func stop() {
        detector = CursorPingDetector()
        dismissNotice()
    }

    private func dismissNotice() {
        guard noticeSession != nil else { return }
        noticeSession = nil
        AgentNotices.dismiss(pill: Self.pillId)
        guard badged else { return }
        badged = false
        let state = AppState.shared
        if state.pendingApproval == nil,
           let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
           state.tasks[i].pillBadge == .approval {
            state.tasks[i].pillBadge = nil
        }
    }

    private func pulse(_ ping: CursorPing) {
        // Cursor switched off in Settings → Edge Light stays off.
        guard EdgeLightSettings.shared.isEnabled(source: .cursor) else { return }
        EdgeLightController.shared.flash(colorHex: ping.colorHex)
    }
}
#endif
