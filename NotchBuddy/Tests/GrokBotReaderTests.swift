#!/usr/bin/swift
// GrokBotReaderTests.swift — standalone test script for Grok Bot blob name mapping and message detection.
// Run from repo root:
//   swift NotchBuddy/Tests/GrokBotReaderTests.swift
//
// The `#else` half runs as a script. At its end it compiles this file again with the real
// GrokBotReader.swift and GrokBotNotice.swift (-D GROKBOT_REAL_READER), which runs the first half.
// All data is synthetic.

import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ desc: String) {
    if actual == expected {
        passed += 1
        print("  ✓ \(desc)")
    } else {
        failed += 1
        print("  ✗ \(desc) — expected: \(expected), got: \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ desc: String) {
    if condition {
        passed += 1
        print("  ✓ \(desc)")
    } else {
        failed += 1
        print("  ✗ \(desc) — expected true")
    }
}

#if GROKBOT_REAL_READER

// MARK: - Pending prompts (real reader)

let nowMs = 1_800_000_000_000
let hourMs = 60 * 60 * 1000
let dayMs = 24 * hourMs

func ask(_ status: String, at ts: Int, action: String = "echo synthetic") -> [String: Any] {
    ["kind": "send-message", "timestampMs": ts,
     "message": ["type": "local-tool-permission",
                 "ask": ["action": action, "target": "t", "machineId": "m",
                         "requestId": "r", "status": status]]]
}

func widget(at ts: Int, prompt: String = "Pick one?", extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = [
        "kind": "send-message", "timestampMs": ts,
        "message": ["type": "widget",
                    "widget": ["prompt": prompt, "options": [["label": "A", "value": "a"]]]]]
    entry.merge(extra) { _, new in new }
    return entry
}

func chat(_ role: String, at ts: Int) -> [String: Any] {
    ["kind": "message", "timestampMs": ts, "message": ["role": role]]
}

func detect(_ entries: [[String: Any]]) -> [GrokBotPendingPrompt] {
    grokBotPendingPrompts(entries: entries, botId: "b1", botName: "Test Bot",
                          color: "#000000", nowMs: nowMs)
}

print("Running pending prompt tests...")

// Approval cards
let pendingAsk = detect([ask("pending", at: nowMs - 1000)])
assertEqual(pendingAsk, [GrokBotPendingPrompt(botId: "b1", botName: "Test Bot", color: "#000000",
                                              kind: .approval, preview: "echo synthetic",
                                              timestampMs: nowMs - 1000)],
            "Pending ask detected")
for status in ["allowed", "expired", "denied", ""] {
    assertTrue(detect([ask(status, at: nowMs - 1000)]).isEmpty, "Ask with status \"\(status)\" ignored")
}
assertTrue(detect([ask("pending", at: nowMs - dayMs - 1)]).isEmpty, "Ask older than 24h ignored")
assertEqual(detect([ask("pending", at: nowMs - dayMs)]).count, 1, "Ask exactly 24h old kept")
assertEqual(detect([ask("pending", at: nowMs - 1000), chat("user", at: nowMs)]).count, 1,
            "Ask stays pending after a user message")
var noTimestamp = ask("pending", at: nowMs)
noTimestamp["timestampMs"] = nil
assertTrue(detect([noTimestamp]).isEmpty, "Ask without a timestamp ignored")

// Question widgets
let pendingWidget = detect([widget(at: nowMs - 1000)])
assertEqual(pendingWidget.map(\.kind), [.question], "Pending widget detected")
assertEqual(pendingWidget.map(\.preview), ["Pick one?"], "Widget preview is its prompt")
assertTrue(detect([widget(at: nowMs - 1000, extra: ["respondedValue": "a"])]).isEmpty,
           "Answered widget ignored")
assertTrue(detect([widget(at: nowMs - 1000, extra: ["respondedValue": ""])]).isEmpty,
           "Widget with an empty answer ignored")
assertTrue(detect([widget(at: nowMs - 1000, extra: ["widgetSkipped": true])]).isEmpty,
           "Skipped widget ignored")
assertEqual(detect([widget(at: nowMs - 1000, extra: ["widgetSkipped": false])]).count, 1,
            "widgetSkipped false stays pending")
assertTrue(detect([widget(at: nowMs - 2000), chat("user", at: nowMs - 1000)]).isEmpty,
           "Widget ignored after a later user message")
assertEqual(detect([chat("user", at: nowMs - 2000), widget(at: nowMs - 1000)]).count, 1,
            "Earlier user message doesn't answer a widget")
assertEqual(detect([widget(at: nowMs - 2000), chat("assistant", at: nowMs - 1000)]).count, 1,
            "Later assistant message doesn't answer a widget")
assertTrue(detect([widget(at: nowMs - dayMs - 1)]).isEmpty, "Widget older than 24h ignored")

// Other entries
let others: [[String: Any]] = ["secret-request", "cursor-agent", "text"].map {
    ["kind": "send-message", "timestampMs": nowMs, "message": ["type": $0, "content": "x"]]
}
assertTrue(detect(others + [["kind": "event", "timestampMs": nowMs]]).isEmpty, "Other types ignored")

// Preview
func preview(_ action: String) -> String { detect([ask("pending", at: nowMs, action: action)]).first?.preview ?? "-" }
assertEqual(preview("\n  first line  \r\nsecond line"), "first line", "Preview is the first non-blank line")
assertEqual(preview(String(repeating: "a", count: 80)), String(repeating: "a", count: 80),
            "80 characters are kept whole")
assertEqual(preview(String(repeating: "a", count: 200)), String(repeating: "a", count: 80) + "…",
            "Long first line is truncated")
assertEqual(preview("ls\t__init__.py `pwd` **/*"), "ls __init__.py `pwd` **/*", "Command characters kept")
assertEqual(preview("a\u{202E}b\u{0007}c"), "abc", "Control and bidi override characters removed")
assertEqual(preview(""), "", "Empty command gives an empty preview")
assertEqual(detect([widget(at: nowMs, prompt: "## **Deploy** [now](https://example.com)?\nDetails")])
                .map(\.preview), ["Deploy now?"], "Widget preview is cleaned of Markdown")

// Order
assertEqual(detect([ask("pending", at: nowMs - 3000), widget(at: nowMs - 1000),
                    ask("pending", at: nowMs - 2000)]).map(\.timestampMs),
            [nowMs - 1000, nowMs - 2000, nowMs - 3000], "Newest first")

// The whole reader, on synthetic blobs in a temporary folder
let blobDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("grokbot-reader-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)

func writeBlob(_ key: String, _ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: ["value": value])
    try data.write(to: blobDir.appendingPathComponent(grokBotBlobName(key)))
}

let prefix = "sand.client.slice.account.test-slot."
try writeBlob("sand.client.slice.client-meta.account-slot", "test-slot")
try writeBlob(prefix + "roster.last-roster", ["rows": [
    ["id": "older", "name": "Older"],
    ["id": "newer", "name": "Newer"],
    ["id": "hidden", "name": "Hidden", "isHiddenFromSidebar": true],
    ["id": "removed", "name": "Removed", "isRemovedFromSidebar": true],
]])
for (botId, ts) in [("older", nowMs - hourMs), ("newer", nowMs - 1000),
                    ("hidden", nowMs), ("removed", nowMs)] {
    try writeBlob(prefix + "transcript.replicas.\(botId)", ["entries": [ask("pending", at: ts)]])
}
let snapshot = GrokBotReader(basePath: blobDir.path).read(nowMs: nowMs)
try FileManager.default.removeItem(at: blobDir)
assertTrue(snapshot.ok, "Synthetic storage is read")
assertEqual(snapshot.pending.map(\.botName), ["Newer", "Older"],
            "Hidden and removed bots ignored, newest first across bots")

// MARK: - Notch notification

print("Running notification tests...")

func message(_ botId: String, at ts: Int, text: String = "synthetic reply") -> GrokBotMessage {
    GrokBotMessage(botId: botId, botName: "Bot \(botId)", color: "", text: text, timestampMs: ts)
}

func prompt(_ botId: String, at ts: Int, _ kind: GrokBotPendingPrompt.Kind = .approval,
            preview: String = "echo synthetic") -> GrokBotPendingPrompt {
    GrokBotPendingPrompt(botId: botId, botName: "Bot \(botId)", color: "", kind: kind,
                         preview: preview, timestampMs: ts)
}

func state(_ messages: [GrokBotMessage] = [], _ pending: [GrokBotPendingPrompt] = [],
           ok: Bool = true) -> GrokBotSnapshot {
    GrokBotSnapshot(bots: [], messages: messages, pending: pending, ok: ok, warning: "")
}

// New messages against the baseline
let messageDetector = GrokBotNewMessageDetector(startMs: nowMs)
assertTrue(messageDetector.filter(state(ok: false)).isEmpty, "Unreadable storage gives no new message")
assertTrue(messageDetector.filter(state([message("a", at: nowMs - 2000), message("a", at: nowMs + 10)])).isEmpty,
           "First readable poll only sets the message baseline")
assertTrue(messageDetector.filter(state([message("a", at: nowMs + 10)])).isEmpty, "Seen message isn't new again")
assertEqual(messageDetector.filter(state([message("a", at: nowMs + 10), message("a", at: nowMs + 20),
                                          message("b", at: nowMs - 1),
                                          message("c", at: nowMs + 30)])).map(\.timestampMs),
            [nowMs + 20, nowMs + 30], "Only messages past the baseline, or past launch for a new bot")

// New prompts against the baseline
let promptDetector = GrokBotNewPromptDetector(startMs: nowMs)
assertTrue(promptDetector.filter(state([], [prompt("a", at: nowMs + 1)], ok: false)).isEmpty,
           "Unreadable storage gives no new prompt")
assertTrue(promptDetector.filter(state([], [prompt("a", at: nowMs + 2)])).isEmpty,
           "First readable poll only sets the prompt baseline")
assertTrue(promptDetector.filter(state([], [prompt("a", at: nowMs + 2)])).isEmpty, "Waiting prompt isn't new again")
assertEqual(promptDetector.filter(state([], [prompt("a", at: nowMs + 3), prompt("a", at: nowMs + 2)]))
                .map(\.timestampMs), [nowMs + 3], "Added prompt is new")
assertTrue(promptDetector.filter(state()).isEmpty, "No prompt, nothing new")
assertTrue(promptDetector.filter(state([], [prompt("a", at: nowMs + 3)])).isEmpty,
           "Prompt that disappeared and came back isn't announced again")
assertTrue(promptDetector.filter(state([], [prompt("late", at: nowMs - 1000)])).isEmpty,
           "Prompt older than the launch is never new")
assertEqual(promptDetector.filter(state([], [prompt("a", at: nowMs + 3, .question)])).map(\.kind), [.question],
            "Another kind at the same time is another prompt")

// The decision
func decide(_ messages: [GrokBotMessage] = [], _ prompts: [GrokBotPendingPrompt] = [],
            enabled: Bool = true, frontmost: String? = "com.example.editor") -> GrokBotNotice? {
    grokBotNotice(newMessages: messages, newPrompts: prompts, enabled: enabled, frontmostBundleId: frontmost)
}

let one = [message("a", at: nowMs)]
assertEqual(decide(one), GrokBotNotice(botId: "a", botName: "Bot a", kind: .message,
                                       preview: "synthetic reply", timestampMs: nowMs, count: 1),
            "One new message is announced")
assertTrue(decide() == nil, "Nothing new, no notice")
assertTrue(decide(one, enabled: false) == nil, "Setting off, no notice")
assertTrue(decide(one, frontmost: "com.anysphere.sand") == nil, "Grok Bot in front, no notice")
assertTrue(decide([], [prompt("a", at: nowMs)], frontmost: "com.anysphere.sand") == nil,
           "Grok Bot in front, no notice for a prompt either")
assertTrue(decide(one, frontmost: nil) != nil, "Unknown frontmost app still notifies")
let several = decide([message("a", at: nowMs + 3, text: "newest"), message("b", at: nowMs + 1),
                      message("a", at: nowMs + 2)])
assertEqual(several?.preview, "newest", "Several at once: the newest is shown")
assertEqual(several?.count, 3, "Several at once: all counted")
let mixed = decide([message("a", at: nowMs + 9)], [prompt("b", at: nowMs + 1, .question),
                                                   prompt("c", at: nowMs + 2)])
assertEqual(mixed?.botId, "c", "A waiting prompt is shown before a message, newest prompt first")
assertEqual(mixed?.kind, .approval, "Approval prompt gives an approval notice")
assertEqual(mixed?.count, 3, "Prompts and messages are counted together")
let widgetTwice = decide([message("a", at: nowMs)], [prompt("a", at: nowMs, .question)])
assertEqual(widgetTwice?.kind, .question, "Question widget gives a question notice")
assertEqual(widgetTwice?.count, 1, "A widget seen as message and prompt counts once")
assertEqual(decide([message("a", at: nowMs, text: "\n  first\u{202E} line \nsecond line")])?.preview, "first line",
            "Notice keeps the first line only, without control characters")
assertEqual(decide([message("a", at: nowMs, text: String(repeating: "a", count: 500))])?.preview,
            String(repeating: "a", count: 80) + "…", "Notice preview is truncated")

#else

// MARK: - Blob name conversion

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

print("Running GrokBotReaderTests...")

// 1. Test blob name conversion for account slot key
let slotKey = "sand.client.slice.client-meta.account-slot"
let slotBlob = grokBotBlobName(slotKey)
assertTrue(slotBlob.hasSuffix(".blob"), "Blob name ends with .blob")
assertTrue(slotBlob.count > 5, "Blob name has reasonable length")
assertTrue(slotBlob.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." }, "Blob name is lowercase")

// 2. Test blob name conversion for a simple key
let simpleKey = "test"
let simpleBlob = grokBotBlobName(simpleKey)
assertTrue(simpleBlob.hasSuffix(".blob"), "Simple key blob ends with .blob")
assertTrue(simpleBlob.count > 5, "Simple key blob has reasonable length")

// 3. Test blob name conversion is deterministic
let key3 = "sand.client.slice.account.test.roster.last-roster"
let blob3a = grokBotBlobName(key3)
let blob3b = grokBotBlobName(key3)
assertEqual(blob3a, blob3b, "Blob name conversion is deterministic")

// 4. Test different keys produce different blob names
let keyA = "sand.client.slice.account.user1.roster"
let keyB = "sand.client.slice.account.user2.roster"
let blobA = grokBotBlobName(keyA)
let blobB = grokBotBlobName(keyB)
assertTrue(blobA != blobB, "Different keys produce different blob names")

// Vectors from Python:
//   base64.b32encode(key.encode()).decode().lower().rstrip('=') + '.blob'
// Lengths 0 to 5 bytes cover every padding case.
let blobVectors: [(key: String, blob: String)] = [
    ("", ".blob"),
    ("a", "me.blob"),
    ("ab", "mfra.blob"),
    ("abc", "mfrgg.blob"),
    ("abcd", "mfrggza.blob"),
    ("abcde", "mfrggzdf.blob"),
    ("abcdef", "mfrggzdfmy.blob"),
    ("account:slot", "mfrwg33vnz2du43mn52a.blob"),
    ("roster/xyz-123", "ojxxg5dfoixxq6l2fuytemy.blob"),
    ("sand.client.slice.client-meta.account-slot",
     "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob"),
    ("café 🤖", "mnqwnq5jedyj7jew.blob"),
]
for vector in blobVectors {
    assertEqual(grokBotBlobName(vector.key), vector.blob, "Blob name for \"\(vector.key)\"")
}

// MARK: - Markdown cleaning

func cleanMarkdown(_ text: String) -> String {
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

// 5. Test markdown link removal
assertEqual(cleanMarkdown("[Click here](https://example.com)"), "Click here", "Links are removed")
assertEqual(cleanMarkdown("See [the docs](url) for details"), "See the docs for details", "Links in text are removed")

// 6. Test bold/italic removal
assertEqual(cleanMarkdown("This is **bold** and __italic__ text"), "This is bold and italic text", "Bold/italic markers removed")
assertEqual(cleanMarkdown("`code` snippet"), "code snippet", "Code markers removed")

// 7. Test list item conversion
assertEqual(cleanMarkdown("- Item one\n- Item two"), "• Item one\n• Item two", "List items use bullets")

// 8. Test heading removal
assertEqual(cleanMarkdown("## Heading\nContent"), "Heading\nContent", "Heading markers removed")
assertEqual(cleanMarkdown("PR #194 is ready"), "PR #194 is ready", "# in PR numbers preserved")

// 9. Test multiple newline collapse
assertEqual(cleanMarkdown("Line 1\n\n\n\nLine 2"), "Line 1\n\nLine 2", "Multiple newlines collapsed")

// MARK: - Timestamp conversion

func timestampToMs(_ value: Any) -> Int {
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
func secondsOrMsToMs(_ num: Double) -> Int {
    let ms = num < 1e11 ? num * 1000 : num
    return Int(exactly: ms.rounded(.towardZero)) ?? 0
}

// 10. Test timestamp conversion from seconds
let ts10 = timestampToMs(1700000000.0)
assertEqual(ts10, 1700000000000, "Seconds to milliseconds")

// 11. Test timestamp conversion from milliseconds
let ts11 = timestampToMs(1700000000000.0)
assertEqual(ts11, 1700000000000, "Milliseconds passthrough")

// 12. Test timestamp conversion from ISO string
let ts12 = timestampToMs("2026-11-27T12:00:00.000Z")
assertTrue(ts12 > 0, "ISO8601 string parsed")

// 13. Test timestamp conversion from invalid string
let ts13 = timestampToMs("invalid")
assertEqual(ts13, 0, "Invalid string returns 0")

// 14. Test values with no Int representation (they used to trap)
for bad in ["nan", "inf", "-inf", "1e300"] {
    assertEqual(timestampToMs(bad), 0, "\"\(bad)\" returns 0")
}
assertEqual(timestampToMs(1e300), 0, "Huge number returns 0")
assertEqual(timestampToMs(Int.min), 0, "Int.min returns 0")

// 15. Pending prompts: compile the real reader with the first half of this file, then run it
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    fflush(stdout)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let testFile = URL(fileURLWithPath: #filePath)
let readerFile = testFile.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/App/GrokBotReader.swift")
let noticeFile = readerFile.deletingLastPathComponent().appendingPathComponent("GrokBotNotice.swift")
let buildDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("grokbot-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
let mainFile = buildDir.appendingPathComponent("main.swift")
try FileManager.default.copyItem(at: testFile, to: mainFile)
let runner = buildDir.appendingPathComponent("runner").path
let compiled = try run("/usr/bin/xcrun", ["swiftc", "-D", "GROKBOT_REAL_READER",
                                          readerFile.path, noticeFile.path, mainFile.path, "-o", runner])
assertEqual(compiled, 0, "Real reader compiles")
if compiled == 0 {
    assertEqual(try run(runner, []), 0, "Pending prompt and notification tests pass")
}
try FileManager.default.removeItem(at: buildDir)

#endif

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
