import Foundation

// MARK: - GrokBot Storage Reader
// Reads Grok Bot's local state from ~/Library/Application Support/Grok Bot/sand-client-persistence/.
//
// Security rules (ported from grokbot.py):
// - Only opens computed blob files for known keys (never lists the directory)
// - Zero network calls
// - Never persists message text to disk (only IDs and timestamps)
// - Display-only text (never opens links or executes content)

/// Maps a key to its blob filename: lowercase unpadded RFC 4648 base32 of the key's UTF-8 bytes + ".blob"
func grokBotBlobName(_ key: String) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var name = ""
    var buffer: UInt32 = 0  // only the low `bits` bits are still pending
    var bits = 0
    for byte in key.utf8 {
        buffer = (buffer << 8) | UInt32(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            name.append(alphabet[Int((buffer >> bits) & 31)])
        }
    }
    // Last group: fill the missing low bits with zeros
    if bits > 0 {
        name.append(alphabet[Int((buffer << (5 - bits)) & 31)])
    }
    return name + ".blob"
}

// MARK: - Keys

private let keyAccountSlot = "sand.client.slice.client-meta.account-slot"

/// What Grok Bot leaves unencoded in a slot (Python's quote(slot, safe="")). ASCII only:
/// CharacterSet.alphanumerics would also let accented and other non-ASCII letters through.
private let slotAllowedCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

private func accountPrefix(_ slot: String) -> String {
    "sand.client.slice.account.\(slot.addingPercentEncoding(withAllowedCharacters: slotAllowedCharacters) ?? slot)."
}

private func keyRoster(_ slot: String) -> String {
    accountPrefix(slot) + "roster.last-roster"
}

private func keyTranscript(_ slot: String, botId: String) -> String {
    accountPrefix(slot) + "transcript.replicas.\(botId)"
}

// MARK: - Models

struct GrokBotMessage: Sendable {
    let botId: String
    let botName: String
    let color: String
    let text: String
    let timestampMs: Int
}

/// An approval card or question widget still waiting for the user. Display-only, held in memory.
struct GrokBotPendingPrompt: Sendable, Equatable {
    enum Kind: Sendable { case approval, question }

    let botId: String
    let botName: String
    let color: String
    let kind: Kind
    let preview: String
    let timestampMs: Int
}

struct GrokBotSnapshot: @unchecked Sendable {
    let bots: [[String: Any]]
    let messages: [GrokBotMessage]
    var pending: [GrokBotPendingPrompt] = []  // newest first
    let ok: Bool
    let warning: String
}

// MARK: - Pending prompts

private let pendingMaxAgeMs = 24 * 60 * 60 * 1000
private let pendingPreviewLength = 80

/// The approval cards and question widgets of one transcript that still wait for the user,
/// newest first. `entries` are in transcript order. Anything older than 24h is ignored.
func grokBotPendingPrompts(entries: [[String: Any]], botId: String, botName: String,
                           color: String, nowMs: Int) -> [GrokBotPendingPrompt] {
    var pending: [GrokBotPendingPrompt] = []
    var userMovedOn = false  // a user message comes after the entry being looked at

    for entry in entries.reversed() {
        let entryKind = entry["kind"] as? String
        let message = entry["message"] as? [String: Any]

        if entryKind == "message", message?["role"] as? String == "user" {
            userMovedOn = true
            continue
        }

        guard entryKind == "send-message", let message,
              let ts = jsonTimestampMs(entry["timestampMs"]),
              ts >= nowMs - pendingMaxAgeMs else { continue }

        let kind: GrokBotPendingPrompt.Kind
        let preview: String

        switch message["type"] as? String {
        case "local-tool-permission":
            guard let ask = message["ask"] as? [String: Any],
                  ask["status"] as? String == "pending" else { continue }
            kind = .approval
            // A command, not Markdown: its characters are shown as written
            preview = grokBotPreviewLine(ask["action"] as? String ?? "")
        case "widget":
            guard !userMovedOn,
                  entry["respondedValue"] == nil,
                  entry["widgetSkipped"] as? Bool != true,
                  let widget = message["widget"] as? [String: Any],
                  let prompt = widget["prompt"] as? String else { continue }
            kind = .question
            preview = grokBotPreviewLine(cleanMarkdown(prompt))
        default:
            continue
        }

        pending.append(GrokBotPendingPrompt(botId: botId, botName: botName, color: color,
                                            kind: kind, preview: preview, timestampMs: ts))
    }

    return pending.sorted { $0.timestampMs > $1.timestampMs }
}

/// The first non-blank line, without control or bidirectional override characters,
/// cut to the preview length.
func grokBotPreviewLine(_ text: String) -> String {
    for line in text.components(separatedBy: .newlines) {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            if scalar == "\t" {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control && !scalar.properties.isBidiControl {
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { continue }
        guard cleaned.count > pendingPreviewLength else { return cleaned }
        return String(cleaned.prefix(pendingPreviewLength)) + "…"
    }
    return ""
}

/// A JSON number of milliseconds, whole or not. nil for anything else, booleans included,
/// and for values with no Int representation.
private func jsonTimestampMs(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int(exactly: number.doubleValue.rounded(.towardZero))
}

// MARK: - Reader

final class GrokBotReader: @unchecked Sendable {
    private let basePath: String
    private var cache: [String: (mtime: Int, size: Int, value: Any?)] = [:]
    private let queue = DispatchQueue(label: "fr.louisraille.GrokBotReader", qos: .background)
    
    init(basePath: String = NSHomeDirectory() + "/Library/Application Support/Grok Bot/sand-client-persistence") {
        self.basePath = basePath
    }
    
    /// Reads a single blob by key (cached by mtime + size)
    private func readKey(_ key: String) -> Any? {
        let blobName = grokBotBlobName(key)
        let path = (basePath as NSString).appendingPathComponent(blobName)
        
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let mtimeInt = Int(exactly: (mtime * 1_000_000).rounded(.towardZero)),
              let size = attrs[.size] as? Int else {
            cache.removeValue(forKey: blobName)
            return nil
        }

        // Check cache
        if let cached = cache[blobName], cached.mtime == mtimeInt, cached.size == size {
            return cached.value
        }
        
        // Read and parse
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] else {
            // On error, keep old cached value if any
            return cache[blobName]?.value
        }
        
        cache[blobName] = (mtime: mtimeInt, size: size, value: value)
        return value
    }
    
    /// Main read: returns a snapshot of bots, messages and waiting prompts
    func read(nowMs: Int = Int(Date().timeIntervalSince1970 * 1000)) -> GrokBotSnapshot {
        // 1. Read account slot
        guard let slot = readKey(keyAccountSlot) as? String, !slot.isEmpty else {
            return GrokBotSnapshot(bots: [], messages: [], ok: false, warning: "Grok Bot account not found")
        }
        
        // 2. Read roster
        guard let roster = readKey(keyRoster(slot)) as? [String: Any],
              let rows = roster["rows"] as? [[String: Any]] else {
            return GrokBotSnapshot(bots: [], messages: [], ok: false, warning: "Bot list not found")
        }
        
        var bots: [[String: Any]] = []
        var messages: [GrokBotMessage] = []
        var pending: [GrokBotPendingPrompt] = []

        for row in rows {
            // Skip hidden bots
            if (row["isHiddenFromSidebar"] as? Bool) == true ||
               (row["isRemovedFromSidebar"] as? Bool) == true {
                continue
            }
            
            guard let botId = row["id"] as? String, !botId.isEmpty else { continue }
            let botName = row["name"] as? String ?? "Bot"
            let botColor = row["avatarColor"] as? String ?? ""
            
            bots.append(row)
            
            // 3. Read transcript
            if let transcript = readKey(keyTranscript(slot, botId: botId)) as? [String: Any],
               let entries = transcript["entries"] as? [[String: Any]] {
                pending += grokBotPendingPrompts(entries: entries, botId: botId, botName: botName,
                                                 color: botColor, nowMs: nowMs)
                for entry in entries {
                    guard entry["kind"] as? String == "send-message" else { continue }
                    guard let ts = jsonTimestampMs(entry["timestampMs"]) else { continue }
                    
                    if let text = extractMessageText(entry), !text.isEmpty {
                        messages.append(GrokBotMessage(
                            botId: botId,
                            botName: botName,
                            color: botColor,
                            text: text,
                            timestampMs: ts
                        ))
                    }
                }
            } else if let newestId = row["newestEntryId"] as? String,
                      newestId.range(of: #"s\d+$"#, options: .regularExpression) != nil,
                      let lastEntry = row["lastEntry"] as? [String: Any],
                      let lastText = lastEntry["text"] as? String,
                      let lastActivity = row["lastActivityAt"] {
                let ts = timestampToMs(lastActivity)
                if !lastText.isEmpty && ts > 0 {
                    messages.append(GrokBotMessage(
                        botId: botId,
                        botName: botName,
                        color: botColor,
                        text: cleanMarkdown(lastText),
                        timestampMs: ts
                    ))
                }
            }
        }
        
        messages.sort { $0.timestampMs < $1.timestampMs }
        pending.sort { $0.timestampMs > $1.timestampMs }
        return GrokBotSnapshot(bots: bots, messages: messages, pending: pending, ok: true, warning: "")
    }
    
    private func extractMessageText(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        let type = message["type"] as? String
        
        if type == "text", let content = message["content"] as? String {
            return cleanMarkdown(content)
        }
        
        if type == "widget" {
            var widget = entry["widget"] as? [String: Any]
            if widget == nil {
                widget = message["widget"] as? [String: Any]
            }
            guard let w = widget else { return nil }
            
            var parts: [String] = []
            if let prompt = w["prompt"] as? String {
                parts.append(prompt)
            }
            if let options = w["options"] as? [[String: Any]] {
                for option in options {
                    if let label = option["label"] as? String {
                        parts.append("• " + label)
                    }
                }
            }
            return parts.joined(separator: "\n")
        }
        
        return nil
    }
    
    private func timestampToMs(_ value: Any) -> Int {
        if let num = value as? Double {
            return secondsOrMsToMs(num)
        }
        if let num = value as? Int {
            guard num < Int(1e11) else { return num }
            let (ms, overflow) = num.multipliedReportingOverflow(by: 1000)
            return overflow ? 0 : ms
        }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) {
                return secondsOrMsToMs(date.timeIntervalSince1970)
            }
            if let num = Double(str) {
                return secondsOrMsToMs(num)
            }
        }
        return 0
    }

    /// 0 when the result doesn't fit in an Int ("nan", "inf", 1e300), where Int(_:) would trap
    private func secondsOrMsToMs(_ num: Double) -> Int {
        let ms = num < 1e11 ? num * 1000 : num
        return Int(exactly: ms.rounded(.towardZero)) ?? 0
    }
}

// MARK: - Markdown cleaning

private func cleanMarkdown(_ text: String) -> String {
    var result = text
    
    // Remove links: [text](url) -> text
    result = result.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#,
                                         with: "$1",
                                         options: .regularExpression)
    
    // Remove bold/italic markers
    result = result.replacingOccurrences(of: "**", with: "")
    result = result.replacingOccurrences(of: "__", with: "")
    result = result.replacingOccurrences(of: "`", with: "")
    
    // Process line by line for line-anchored patterns
    let lines = result.components(separatedBy: .newlines)
    var processedLines: [String] = []
    
    for line in lines {
        var processed = line
        
        // List items: - text -> • text
        if let range = processed.range(of: #"^([ \t]*)[-*][ \t]+"#, options: .regularExpression) {
            let leadingSpace = processed[..<range.upperBound].replacingOccurrences(of: #"[-*][ \t]+"#, with: "", options: .regularExpression)
            let rest = processed[range.upperBound...]
            processed = leadingSpace + "• " + rest
        }
        
        // Remove heading markers (but keep # in "PR #194")
        if let range = processed.range(of: #"^[ \t]*#{1,6}[ \t]*"#, options: .regularExpression) {
            processed.removeSubrange(range)
        }
        
        processedLines.append(processed)
    }
    
    result = processedLines.joined(separator: "\n")
    
    // Collapse multiple newlines
    result = result.replacingOccurrences(of: #"\n{3,}"#,
                                         with: "\n\n",
                                         options: .regularExpression)
    
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - New message detection

final class GrokBotNewMessageDetector: @unchecked Sendable {
    private var lastTimestamps: [String: Int] = [:] // botId -> timestampMs
    private var initialized = false
    private let startMs: Int
    
    init(startMs: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        self.startMs = startMs
    }
    
    /// Filters messages that are new since the last call
    func filter(_ snapshot: GrokBotSnapshot) -> [GrokBotMessage] {
        guard snapshot.ok else { return [] }
        
        var perBot: [String: [GrokBotMessage]] = [:]
        for msg in snapshot.messages {
            perBot[msg.botId, default: []].append(msg)
        }
        
        var newMessages: [GrokBotMessage] = []
        
        for (botId, msgs) in perBot {
            guard let maxTs = msgs.map(\.timestampMs).max() else { continue }
            
            if !initialized {
                // First run: anchor to latest, don't notify
                lastTimestamps[botId] = maxTs
            } else {
                let baseline = lastTimestamps[botId] ?? startMs
                let new = msgs.filter { $0.timestampMs > baseline }
                newMessages.append(contentsOf: new)
                lastTimestamps[botId] = max(baseline, maxTs)
            }
        }
        
        initialized = true
        newMessages.sort { $0.timestampMs < $1.timestampMs }
        return newMessages
    }
}
