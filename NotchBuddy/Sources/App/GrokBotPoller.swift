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
                self.syncAttentionBadge()
            }
            return
        }
        
        let newMessages = detector.filter(snapshot)
        
        DispatchQueue.main.async {
            self.handleSnapshot(snapshot, newMessages: newMessages)
        }
    }
    
    @MainActor
    private func handleSnapshot(_ snapshot: GrokBotSnapshot, newMessages: [GrokBotMessage]) {
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

        // Handle new messages
        guard let newest = newMessages.last else { return }
        guard let taskIdx = state.tasks.firstIndex(where: { $0.id == "agent_grokbot" }) else { return }

        let focused = state.focusId == "agent_grokbot"

        // Show the newest message
        state.tasks[taskIdx].state = .finished
        state.tasks[taskIdx].steps = ["\(newest.botName): \(preview(newest.text))"]
        
        if !focused {
            state.tasks[taskIdx].pillBadge = .finished
        }
        
        // Play sound and trigger Mochi reaction
        SoundEngine.shared.play("finish")
        
        // Trigger edge light
        #if !APPSTORE
        EdgeLightController.shared.trigger(source: .grokBot)
        #endif
        
        // Auto-clear after 60s
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "agent_grokbot" }) else { return }
            guard state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
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

    /// Creates a short preview of the message text (first 60 chars)
    private func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 {
            return trimmed
        }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 60)
        return String(trimmed[..<idx]) + "…"
    }
}
