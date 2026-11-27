import Foundation

// MARK: - GrokBot Storage Reader
// Reads Grok Bot's local state from ~/Library/Application Support/Grok Bot/sand-client-persistence/.
//
// Security rules (ported from grokbot.py):
// - Only opens computed blob files for known keys (never lists the directory)
// - Zero network calls
// - Never persists message text to disk (only IDs and timestamps)
// - Display-only text (never opens links or executes content)

/// Maps a key to its blob filename: lowercase unpadded base32 of the key + ".blob"
func grokBotBlobName(_ key: String) -> String {
    guard let data = key.data(using: .utf8) else { return "" }
    let base32 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "")
        .replacingOccurrences(of: "/", with: "")
        .replacingOccurrences(of: "=", with: "")
        .lowercased()
    
    // Convert base64 to base32 manually
    var result = ""
    for char in data {
        let binary = String(char, radix: 2).padding(toLength: 8, withPad: "0", startingAt: 0)
        result += binary
    }
    
    // Group into 5-bit chunks and convert to base32
    let base32Alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    var base32Result = ""
    var i = 0
    while i < result.count {
        let end = min(i + 5, result.count)
        let chunk = String(result[result.index(result.startIndex, offsetBy: i)..<result.index(result.startIndex, offsetBy: end)])
        let padded = chunk.padding(toLength: 5, withPad: "0", startingAt: chunk.count)
        if let value = Int(padded, radix: 2), value < base32Alphabet.count {
            let idx = base32Alphabet.index(base32Alphabet.startIndex, offsetBy: value)
            base32Result.append(base32Alphabet[idx])
        }
        i += 5
    }
    
    return base32Result.trimmingCharacters(in: CharacterSet(charactersIn: "=")) + ".blob"
}

// MARK: - Keys

private let keyAccountSlot = "sand.client.slice.client-meta.account-slot"

private func accountPrefix(_ slot: String) -> String {
    "sand.client.slice.account.\(slot.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slot)."
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

struct GrokBotSnapshot: @unchecked Sendable {
    let bots: [[String: Any]]
    let messages: [GrokBotMessage]
    let ok: Bool
    let warning: String
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
              let size = attrs[.size] as? Int else {
            cache.removeValue(forKey: blobName)
            return nil
        }
        
        let mtimeInt = Int(mtime * 1_000_000)
        
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
    
    /// Main read: returns a snapshot of bots and messages
    func read() -> GrokBotSnapshot {
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
                for entry in entries {
                    guard entry["kind"] as? String == "send-message" else { continue }
                    guard let ts = entry["timestampMs"] as? Int else { continue }
                    
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
        return GrokBotSnapshot(bots: bots, messages: messages, ok: true, warning: "")
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
            return num < 1e11 ? Int(num * 1000) : Int(num)
        }
        if let num = value as? Int {
            return num < Int(1e11) ? num * 1000 : num
        }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) {
                return Int(date.timeIntervalSince1970 * 1000)
            }
            if let num = Double(str) {
                return Int(num < 1e11 ? num * 1000 : num)
            }
        }
        return 0
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
    
    init() {
        self.startMs = Int(Date().timeIntervalSince1970 * 1000)
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
