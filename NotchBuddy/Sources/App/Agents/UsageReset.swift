#if !APPSTORE
import Foundation

// MARK: - When the Claude usage limit resets (pure logic)
// The real time comes from `rate_limits` in Claude Code's status line input (ClaudePlanGauge).
// Without it, a daily time the user sets stands in, and is always said to be an estimate.

/// A time of day, "18:30".
struct DailyResetTime: Equatable, Sendable {
    let hour: Int
    let minute: Int

    static let fallback = DailyResetTime(hour: 18, minute: 30)

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// nil unless the text is a valid "H:mm" on the 24-hour clock.
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    var text: String { String(format: "%02d:%02d", hour, minute) }
}

struct UsageResetInfo: Equatable, Sendable {
    enum Window: Equatable, Sendable { case fiveHour, week }
    enum Source: Equatable, Sendable {
        /// Reported by Claude Code
        case claudeCode(Window, usedPct: Double)
        /// The user's daily time: nothing live is known
        case estimate
    }

    let resetsAt: Date
    let source: Source

    var isEstimate: Bool { source == .estimate }
}

enum UsageReset {
    /// The first time the clock reads `time` strictly after `now`. A time skipped by the
    /// spring change counts as the moment the clock jumps; a repeated one counts once.
    static func nextDaily(_ time: DailyResetTime, after now: Date, calendar: Calendar) -> Date {
        // Day by day: Calendar.nextDate can give the second reading of a repeated time.
        let today = calendar.startOfDay(for: now)
        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let at = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day,
                                         matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                         direction: .forward)
            else { continue }
            if at > now { return at }
        }
        return now.addingTimeInterval(86400)
    }

    /// The limit to count down to: a used-up week blocks until it resets; else the running
    /// 5-hour window; else the running week; else the estimate. A window whose reset time
    /// has passed says nothing about the next one.
    static func compute(usage: PlanUsage?, daily: DailyResetTime, now: Date,
                        calendar: Calendar) -> UsageResetInfo {
        func live(_ window: PlanWindow?) -> PlanWindow? {
            guard let window, window.resetsAt > now else { return nil }
            return window
        }
        let five = live(usage?.fiveHour)
        let week = live(usage?.sevenDay)
        if let week, week.usedPct >= 100 {
            return UsageResetInfo(resetsAt: week.resetsAt, source: .claudeCode(.week, usedPct: week.usedPct))
        }
        if let five {
            return UsageResetInfo(resetsAt: five.resetsAt, source: .claudeCode(.fiveHour, usedPct: five.usedPct))
        }
        if let week {
            return UsageResetInfo(resetsAt: week.resetsAt, source: .claudeCode(.week, usedPct: week.usedPct))
        }
        return UsageResetInfo(resetsAt: nextDaily(daily, after: now, calendar: calendar), source: .estimate)
    }
}

/// A length of time as it is said: whole minutes, with hours and days above them.
enum DurationParts: Equatable, Sendable {
    case underMinute
    case minutes(Int)
    case hours(Int, minutes: Int)
    case days(Int, hours: Int)

    /// `roundUp` for a countdown ("1 min" until the very end), down for time elapsed.
    static func of(_ seconds: TimeInterval, roundUp: Bool = false) -> DurationParts {
        let minutes = Int((max(0, seconds) / 60).rounded(roundUp ? .up : .down))
        if minutes < 1 { return .underMinute }
        if minutes < 60 { return .minutes(minutes) }
        if minutes < 24 * 60 { return .hours(minutes / 60, minutes: minutes % 60) }
        return .days(minutes / (24 * 60), hours: minutes % (24 * 60) / 60)
    }
}
#endif
