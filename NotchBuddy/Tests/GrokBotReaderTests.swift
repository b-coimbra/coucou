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

/// Maps a key to its blob filename: lowercase unpadded base32 of the key + ".blob"
func grokBotBlobName(_ key: String) -> String {
    guard let data = key.data(using: .utf8) else { return "" }
    
    // Convert to base32
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
    
    // List items: - text -> • text
    result = result.replacingOccurrences(of: #"^([ \t]*)[-*][ \t]+"#,
                                         with: "$1• ",
                                         options: .regularExpression)
    
    // Remove heading markers (but keep # in "PR #194")
    result = result.replacingOccurrences(of: #"^[ \t]*#{1,6}[ \t]*"#,
                                         with: "",
                                         options: [.regularExpression, .anchorsMatchLines])
    
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

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
