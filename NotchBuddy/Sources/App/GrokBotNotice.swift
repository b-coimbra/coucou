import Foundation

// MARK: - Grok Bot notch notification (pure logic)
// What is announced, and when. No AppKit, no AppState, no file access.
// A notice holds message text: it lives in memory only, never written to disk or logged.

let grokBotBundleId = "com.anysphere.sand"

/// UserDefaults key of the notification switch (on until turned off).
let grokBotNotificationsKey = "grokBotNotifications"

/// What the notch shows: the newest new item, and how many arrived with it.
struct GrokBotNotice: Sendable, Equatable {
    enum Kind: Sendable { case message, approval, question }

    let botId: String
    let botName: String
    let kind: Kind
    /// The first line only, truncated
    let preview: String
    let timestampMs: Int
    let count: Int
}

/// Which waiting prompts weren't there before. Remembers ids and timestamps, never text.
final class GrokBotNewPromptDetector: @unchecked Sendable {
    private struct Key: Hashable {
        let botId: String
        let kind: GrokBotPendingPrompt.Kind
        let timestampMs: Int
    }

    private var seen: Set<Key> = []
    private var initialized = false
    private let startMs: Int

    init(startMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        self.startMs = startMs
    }

    /// The prompts that appeared since the last call, newest first. The first readable snapshot
    /// only sets the baseline, and a prompt older than the launch is never new (its transcript
    /// may not have been readable at first).
    func filter(_ snapshot: GrokBotSnapshot) -> [GrokBotPendingPrompt] {
        guard snapshot.ok else { return [] }
        var new: [GrokBotPendingPrompt] = []
        for prompt in snapshot.pending {
            let key = Key(botId: prompt.botId, kind: prompt.kind, timestampMs: prompt.timestampMs)
            // Kept after it disappears: a transcript that fails to read once isn't announced again
            if seen.insert(key).inserted && initialized && prompt.timestampMs > startMs {
                new.append(prompt)
            }
        }
        initialized = true
        return new
    }
}

/// The notice to show for what just arrived, or nil: nothing new, notifications off,
/// or Grok Bot already in front. A waiting prompt is shown before a message, then the newest wins.
func grokBotNotice(newMessages: [GrokBotMessage], newPrompts: [GrokBotPendingPrompt],
                   enabled: Bool, frontmostBundleId: String?) -> GrokBotNotice? {
    guard enabled, frontmostBundleId != grokBotBundleId else { return nil }

    // A question widget is also a message of the transcript: counted once
    let messages = newMessages.filter { message in
        !newPrompts.contains { $0.botId == message.botId && $0.timestampMs == message.timestampMs }
    }
    let count = messages.count + newPrompts.count

    if let prompt = newPrompts.max(by: { $0.timestampMs < $1.timestampMs }) {
        return GrokBotNotice(botId: prompt.botId, botName: grokBotPreviewLine(prompt.botName),
                             kind: prompt.kind == .approval ? .approval : .question,
                             preview: grokBotPreviewLine(prompt.preview),
                             timestampMs: prompt.timestampMs, count: count)
    }
    guard let message = messages.max(by: { $0.timestampMs < $1.timestampMs }) else { return nil }
    return GrokBotNotice(botId: message.botId, botName: grokBotPreviewLine(message.botName),
                         kind: .message, preview: grokBotPreviewLine(message.text),
                         timestampMs: message.timestampMs, count: count)
}
