#if !APPSTORE
import Foundation

// MARK: - Dock badges (pure logic, tested by scripts/test-glance.sh)
// What `lsappinfo` answers, what a badge label says, and the two pills that show it. No AppKit.

/// What the Dock shows on an app's icon. The label itself is never kept: only this.
enum DockBadge: Equatable, Sendable {
    /// No badge
    case none
    /// Unread without a count ("•")
    case unread
    /// `more` when the badge says "99+"
    case count(Int, more: Bool = false)

    /// Anything to show
    var isUnread: Bool { self != .none }

    /// "3", "99+" or "•"; nil without a badge.
    var text: String? {
        switch self {
        case .none:                    return nil
        case .unread:                  return "•"
        case .count(let n, let more):  return more ? "\(n)+" : "\(n)"
        }
    }

    /// Larger counts are cut here
    static let maxCount = 999_999

    /// A badge label: digits (with group separators, and a "+" at the end) are a count, "0"
    /// and nothing are no badge, anything else is unread without a count.
    static func parse(_ label: String?) -> DockBadge {
        var text = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        var more = false
        if let last = text.last, last == "+" || last == "＋" {
            more = true
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // "1,234", "1.234", "1 234", "1’234", and the marks right-to-left systems add
        let ignored: Set<Unicode.Scalar> = [",", ".", " ", "'", "\u{00A0}", "\u{202F}", "\u{2009}",
                                            "\u{2019}", "\u{066C}", "\u{200E}", "\u{200F}", "\u{061C}"]
        let scalars = text.unicodeScalars.filter { !ignored.contains($0) }
        guard !scalars.isEmpty, scalars.allSatisfy({ $0.properties.numericType == .decimal }) else {
            // A mark with no digit at all, or text: something is unread.
            return .unread
        }
        var total = 0
        for scalar in scalars {
            total = min(maxCount, total * 10 + Int(scalar.properties.numericValue ?? 0))
        }
        return total == 0 ? .none : .count(total, more: more)
    }
}

/// One look at an app's badge.
enum DockBadgeReading: Equatable, Sendable {
    /// The label on the app's icon, empty without a badge
    case label(String)
    case notRunning
    /// `lsappinfo` didn't answer, or answered something else
    case unavailable

    /// An app that isn't running has no badge; nil when nothing could be read.
    var badge: DockBadge? {
        switch self {
        case .label(let label): return DockBadge.parse(label)
        case .notRunning:       return DockBadge.none
        case .unavailable:      return nil
        }
    }
}

/// The two answers of `lsappinfo` that are read.
enum LSAppInfo {
    /// The application serial number in the answer to `find`; nil when no such app runs.
    static func asn(in output: String) -> String? {
        guard let range = output.range(of: "ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:",
                                       options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// The label in the answer to `info -only StatusLabel` (`"StatusLabel"={ "label"="3" }`):
    /// empty without a badge, nil when the answer is something else.
    static func statusLabel(in output: String) -> String? {
        if let range = output.range(of: #""label"\s*=\s*"([^"]*)""#, options: .regularExpression) {
            let match = output[range]
            // The value between the last pair of quotes
            if let value = match.range(of: #""[^"]*"$"#, options: .regularExpression) {
                return String(match[value].dropFirst().dropLast())
            }
        }
        if output.contains("StatusLabel") || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        return nil
    }
}

/// The apps that have a badge pill.
enum BadgeApp: String, CaseIterable, Sendable {
    case slack, mail

    var bundleId: String {
        switch self {
        case .slack: return "com.tinyspeck.slackmacgap"
        case .mail:  return "com.apple.mail"
        }
    }

    var pillId: String {
        switch self {
        case .slack: return BadgePills.slack
        case .mail:  return BadgePills.mail
        }
    }

    init?(pillId: String) {
        guard let app = Self.allCases.first(where: { $0.pillId == pillId }) else { return nil }
        self = app
    }
}

/// The badge pills (declared in PillCatalog) and their one-time switch-on. Their switches
/// are the pills' own (AppState.activeIntegrations).
enum BadgePills {
    static let slack = "integration_slack_badge"
    static let mail = "integration_mail_badge"
    static let all = [slack, mail]

    /// The pills already switched on once: one turned off by the user stays off.
    static let seededKey = "badges.seededPills"

    static func contains(_ id: String) -> Bool { all.contains(id) }

    /// The saved pill choice with the badge pills it has never seen switched on, written
    /// back to `defaults`. Unchanged once every pill has been seeded.
    static func seed(_ active: Set<String>, defaults: UserDefaults) -> Set<String> {
        let done = Set(defaults.stringArray(forKey: seededKey) ?? [])
        let new = all.filter { !done.contains($0) }
        guard !new.isEmpty else { return active }
        let result = active.union(new)
        if let data = try? JSONEncoder().encode(Array(result)) {
            defaults.set(data, forKey: "activeIntegrations")
        }
        defaults.set(all, forKey: seededKey)
        return result
    }
}
#endif
