#!/usr/bin/swift
// EdgeLightBadgeTests.swift — standalone test script for badge count parsing
// Run from repo root:
//   swift NotchBuddy/Tests/EdgeLightBadgeTests.swift

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

// MARK: - Badge Count Parsing

func parseBadgeCount(label: String) -> Int {
    guard !label.isEmpty else { return 0 }
    
    // Try to extract number
    if let match = label.range(of: #"\d+"#, options: .regularExpression) {
        if let num = Int(label[match]) {
            return num
        }
    }
    
    // "•" or other non-numeric indicator = 1
    return 1
}

// MARK: - ASN Extraction

func extractASN(_ output: String) -> String? {
    let pattern = "ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:"
    if let range = output.range(of: pattern, options: .regularExpression) {
        return String(output[range])
    }
    return nil
}

// MARK: - Status Label Extraction

func extractStatusLabel(_ output: String) -> String? {
    let pattern = #""label"\s*=\s*"([^"]*)""#
    if let range = output.range(of: pattern, options: .regularExpression) {
        let match = output[range]
        if let valueRange = match.range(of: #""[^"]*"$"#, options: .regularExpression) {
            var value = String(match[valueRange])
            value.removeFirst()
            value.removeLast()
            return value
        }
    }
    
    // Empty label
    if output.contains("StatusLabel") || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return ""
    }
    
    return nil
}

print("Running EdgeLightBadgeTests...")

// 1. Badge count parsing: numeric
assertEqual(parseBadgeCount(label: "3"), 3, "Parse numeric badge '3'")
assertEqual(parseBadgeCount(label: "17"), 17, "Parse numeric badge '17'")
assertEqual(parseBadgeCount(label: "99"), 99, "Parse numeric badge '99'")

// 2. Badge count parsing: special cases
assertEqual(parseBadgeCount(label: "99+"), 99, "Parse '99+' as 99")
assertEqual(parseBadgeCount(label: "•"), 1, "Parse bullet '•' as 1")
assertEqual(parseBadgeCount(label: ""), 0, "Empty label is 0")
assertEqual(parseBadgeCount(label: "new"), 1, "Non-numeric text is 1")

// 3. Badge count parsing: with spaces
assertEqual(parseBadgeCount(label: " 5 "), 1, "Leading/trailing spaces (would extract 5 if trimmed)")
assertEqual(parseBadgeCount(label: "12 messages"), 12, "Number within text extracts first number")

// 4. ASN extraction
let asnOutput1 = "ASN:0x0-0x123abc:"
assertEqual(extractASN(asnOutput1), "ASN:0x0-0x123abc:", "Extract valid ASN")

let asnOutput2 = "No ASN here"
assertEqual(extractASN(asnOutput2), nil, "No ASN returns nil")

let asnOutput3 = "Before ASN:0xa1b2-0xc3d4: after"
assertEqual(extractASN(asnOutput3), "ASN:0xa1b2-0xc3d4:", "Extract ASN from middle of output")

// 5. Status label extraction
let labelOutput1 = #""label" = "5""#
assertEqual(extractStatusLabel(labelOutput1), "5", "Extract simple numeric label")

let labelOutput2 = #""label" = "•""#
assertEqual(extractStatusLabel(labelOutput2), "•", "Extract bullet label")

let labelOutput3 = #""label" = """#
assertEqual(extractStatusLabel(labelOutput3), "", "Extract empty label")

let labelOutput4 = "StatusLabel = (null)"
assertEqual(extractStatusLabel(labelOutput4), "", "Null StatusLabel returns empty")

let labelOutput5 = "No label here at all"
assertEqual(extractStatusLabel(labelOutput5), nil, "Missing StatusLabel returns nil")

let labelOutput6 = #""label"="99+""#
assertEqual(extractStatusLabel(labelOutput6), "99+", "Extract label without spaces")

// 6. Bundle IDs
let slackBundle = "com.tinyspeck.slackmacgap"
let mailBundle = "com.apple.mail"

assertEqual(slackBundle.contains("slack"), true, "Slack bundle ID contains 'slack'")
assertEqual(mailBundle.contains("mail"), true, "Mail bundle ID contains 'mail'")

// 7. Count increase detection logic
var lastCount: Int? = nil
var newCount = 3

// First read: no trigger (establish baseline)
let shouldTrigger1 = lastCount != nil && newCount > lastCount!
assertEqual(shouldTrigger1, false, "First read doesn't trigger")
lastCount = newCount

// Count stays same: no trigger
newCount = 3
let shouldTrigger2 = lastCount != nil && newCount > lastCount!
assertEqual(shouldTrigger2, false, "Same count doesn't trigger")

// Count increases: trigger
newCount = 5
let shouldTrigger3 = lastCount != nil && newCount > lastCount!
assertEqual(shouldTrigger3, true, "Increased count triggers")
lastCount = newCount

// Count decreases: no trigger
newCount = 2
let shouldTrigger4 = lastCount != nil && newCount > lastCount!
assertEqual(shouldTrigger4, false, "Decreased count doesn't trigger")

// 8. App not running (nil) resets state
lastCount = nil
newCount = 10
let shouldTrigger5 = lastCount != nil && newCount > lastCount!
assertEqual(shouldTrigger5, false, "Nil (app closed) doesn't trigger")

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
