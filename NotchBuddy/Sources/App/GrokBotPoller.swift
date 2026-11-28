import AppKit
import Foundation
import SwiftUI

// MARK: - GrokBotPoller
// Polls Grok Bot's local storage every 2s for new assistant messages and waiting prompts.
// Security: file access only (no network), off the main thread, only computed blob paths.

final class GrokBotPoller: @unchecked Sendable {
    static let shared = GrokBotPoller()
    
    private var timer: DispatchSourceTimer?
    /// Serial: the reader's cache and the detector must never be used by two polls at once
    private let queue = DispatchQueue(label: "fr.louisraille.GrokBotPoller", qos: .background)
    private let reader: GrokBotReader
    private let detector: GrokBotNewMessageDetector
    private let promptDetector = GrokBotNewPromptDetector()
    /// Counts the announcements, so an older auto-clear leaves a newer one alone
    @MainActor private var announcement = 0
    private static let pillId = "agent_grokbot"

    private init() {
        self.reader = GrokBotReader()
        self.detector = GrokBotNewMessageDetector()
    }
    
    func start() {
        guard timer == nil else { return }
        
        // Poll every 2 seconds as specified
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }
    
    func stop() {
        timer?.cancel()
        timer = nil
    }
    
    // MARK: - Poll
    
    func pollNow() { queue.async { [weak self] in self?.poll() } }
    
    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        
        let snapshot = reader.read()
        
        guard snapshot.ok else {
            // Not an error — user might not have Grok Bot installed
            DispatchQueue.main.async {
                AppState.shared.setIfChanged(\.grokBotLoaded, false)
                AppState.shared.setIfChanged(\.grokBotError, snapshot.warning.isEmpty ? nil : snapshot.warning)
                AppState.shared.setIfChanged(\.grokBotPending, [])
                AppState.shared.setIfChanged(\.grokBotUnread, false)
                self.dismissNotice()
                self.syncAttentionBadge()
            }
            return
        }

        // Both baselines move on every poll, whatever is announced: nothing piles up
        let newMessages = detector.filter(snapshot)
        let newPrompts = promptDetector.filter(snapshot)

        DispatchQueue.main.async {
            self.handleSnapshot(snapshot, newMessages: newMessages, newPrompts: newPrompts)
        }
    }

    @MainActor
    private func handleSnapshot(_ snapshot: GrokBotSnapshot, newMessages: [GrokBotMessage],
                                newPrompts: [GrokBotPendingPrompt]) {
        let state = AppState.shared
        
        state.setIfChanged(\.grokBotError, nil)
        state.setIfChanged(\.grokBotLoaded, true)
        
        // Update bot list
        state.grokBotBots = snapshot.bots
        
        // Update latest message per bot (for display)
        var latest: [String: GrokBotMessage] = [:]
        for msg in snapshot.messages {
            if latest[msg.botId] == nil || msg.timestampMs > (latest[msg.botId]?.timestampMs ?? 0) {
                latest[msg.botId] = msg
            }
        }
        state.grokBotLatestMessages = latest

        // Waiting prompts. The badge is synced on the way out, so it wins over "finished" below.
        state.setIfChanged(\.grokBotPending, snapshot.pending)
        defer { syncAttentionBadge() }

        // A notice for a prompt answered since has nothing left to say
        if let shown = state.grokBotNotice, shown.kind != .message,
           !snapshot.pending.contains(where: { $0.botId == shown.botId && $0.timestampMs == shown.timestampMs }) {
            dismissNotice()
        }

        announce(newMessages: newMessages, newPrompts: newPrompts)
    }

    /// Reacts to what just arrived. The message text goes to the notice only (memory): never into
    /// the pill's steps, which the phone links send off the Mac.
    @MainActor
    private func announce(newMessages: [GrokBotMessage], newPrompts: [GrokBotPendingPrompt]) {
        guard !newMessages.isEmpty || !newPrompts.isEmpty else { return }
        let state = AppState.shared
        guard let taskIdx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let enabled = UserDefaults.standard.object(forKey: grokBotNotificationsKey) as? Bool ?? true
        let notice = grokBotNotice(newMessages: newMessages, newPrompts: newPrompts,
                                   enabled: enabled, frontmostBundleId: frontmost)
        let focused = state.focusId == Self.pillId

        if !newMessages.isEmpty {
            // Unread for the notch glance, unless it is being looked at.
            let onCard = state.mode == .expanded && state.view == .overview && focused
            if frontmost != grokBotBundleId && !onCard { state.setIfChanged(\.grokBotUnread, true) }
            state.tasks[taskIdx].state = .finished
            state.tasks[taskIdx].steps = []
            if !focused { state.tasks[taskIdx].pillBadge = .finished }
        }

        // Grok Bot in front: the user is looking at it, no sound and no light
        let sound: String? = switch notice?.kind {
        case .approval: "approval"
        case .question: "question"
        case .message: "finish"
        case nil: !newMessages.isEmpty && frontmost != grokBotBundleId ? "finish" : nil
        }
        if let sound {
            SoundEngine.shared.play(sound)
            #if !APPSTORE
            EdgeLightController.shared.trigger(source: .grokBot)
            #endif
        }

        if let notice {
            // Set first: the card reads it as soon as the island opens
            state.grokBotNotice = notice
            if HookServer.shared.presentNotice(pill: Self.pillId) {
                if let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
                    state.tasks[i].pillBadge = nil
                }
            } else {
                // The user is busy in a card: the pill's badge says it instead
                state.grokBotNotice = nil
                if !focused { state.setPillBadge(.finished, for: Self.pillId) }
            }
        }

        // Auto-clear after 60s
        announcement += 1
        let current = announcement
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.announcement == current else { return }
            self.dismissNotice()
            let state = AppState.shared
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
            guard state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }

    /// Forgets the notice. If its card is on screen, the overview takes its place.
    @MainActor
    private func dismissNotice() {
        let state = AppState.shared
        guard state.grokBotNotice != nil else { return }
        if state.mode == .expanded && state.view == .finished && state.focusId == Self.pillId {
            state.view = .overview
        }
        state.grokBotNotice = nil
    }

    /// The attention badge stays on the pill while a prompt waits. Checked on every poll,
    /// because focusing the pill and the "finished" auto-clear both remove badges.
    @MainActor
    private func syncAttentionBadge() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == "agent_grokbot" }) else { return }
        if !state.grokBotPending.isEmpty {
            if state.tasks[i].pillBadge != .approval { state.tasks[i].pillBadge = .approval }
        } else if state.tasks[i].pillBadge == .approval {
            state.tasks[i].pillBadge = nil
        }
    }
}
