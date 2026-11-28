#if !APPSTORE
import Foundation

// MARK: - Cursor agent: finished or waiting (pure logic)
// Cursor runs Coucou's Claude Code hooks, but only some of them: Stop (with a `status`),
// PreToolUse, PostToolUse, SessionStart and SessionEnd. It has no PermissionRequest and no
// Notification; those only come from Claude Code running inside Cursor.

enum CursorPing: Equatable, Sendable {
    case finished
    /// A turn that ended on an error
    case failed
    case needsInput

    /// Blue when done, amber when it is your turn.
    var colorHex: String { self == .finished ? "#3B9EFF" : "#F5A524" }
}

/// Tells the changes worth a light from the events that merely repeat them.
struct CursorPingDetector: Sendable {
    /// Cursor's own question tool. Claude Code's (AskUserQuestion) has its card instead.
    static let askTool = "AskQuestion"
    private static let repeatWindow: TimeInterval = 2
    private static let maxRemembered = 64

    private struct Stop: Sendable {
        let generation: String
        let at: Date
    }

    private var waiting: Set<String> = []
    private var stops: [String: Stop] = [:]

    func isWaiting(_ session: String) -> Bool { waiting.contains(session) }

    /// What a hook event changes. nil: nothing to announce.
    mutating func event(_ name: String, session: String, tool: String = "", message: String = "",
                        status: String = "", generation: String = "", now: Date = Date()) -> CursorPing? {
        switch name {
        case "Stop":
            waiting.remove(session)
            if let last = stops[session] {
                let same = generation.isEmpty
                    ? now.timeIntervalSince(last.at) < Self.repeatWindow
                    : last.generation == generation
                if same { return nil }
            }
            if stops.count >= Self.maxRemembered { stops.removeAll() }
            stops[session] = Stop(generation: generation, at: now)
            switch status {
            case "aborted": return nil  // the user stopped it
            case "error":   return .failed
            default:        return .finished
            }
        case "PreToolUse":
            // Sent beside the question card's own hook, in either order.
            if tool == "AskUserQuestion" { return nil }
            if tool == Self.askTool { return needsInput(session) }
            waiting.remove(session)
        case "Notification":
            if message.hasSuffix("?") { return needsInput(session) }
        case "SessionEnd":
            waiting.remove(session)
            stops.removeValue(forKey: session)
        case "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "StopFailure", "Interrupt", "SessionStart":
            waiting.remove(session)
        default:
            break
        }
        return nil
    }

    /// A permission or question card went up for this session. Each request is its own news.
    mutating func requestShown(session: String) -> CursorPing {
        waiting.insert(session)
        return .needsInput
    }

    private mutating func needsInput(_ session: String) -> CursorPing? {
        waiting.insert(session).inserted ? .needsInput : nil
    }
}
#endif
