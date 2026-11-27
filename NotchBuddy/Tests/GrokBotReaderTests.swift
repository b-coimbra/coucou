#!/usr/bin/swift
// GrokBotReaderTests.swift — standalone test script for Grok Bot blob name mapping and message detection.
// Run from repo root:
//   swift NotchBuddy/Tests/GrokBotReaderTests.swift

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

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
