#if !APPSTORE
import Foundation

// MARK: - When the weekly timesheet reminder shows (pure logic)

struct TimesheetSchedule: Sendable, Equatable {
    /// Calendar's numbering: 1 is Sunday, 6 is Friday.
    let weekday: Int
    let time: DailyResetTime

    static let fallbackWeekday = 6
    static let fallbackTime = DailyResetTime(hour: 16, minute: 0)

    init(weekday: Int, time: DailyResetTime) {
        self.weekday = (1...7).contains(weekday) ? weekday : Self.fallbackWeekday
        self.time = time
    }

    /// "2026-W48": the ISO week `date` falls in, in `timeZone`. Its year is the week's, which
    /// around New Year is not always the date's.
    static func isoWeek(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// true on the chosen weekday from the chosen local time until midnight, unless that
    /// week's reminder was dismissed.
    func isDue(_ now: Date, dismissedWeek: String?, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard parts.weekday == weekday,
              (parts.hour ?? 0) * 60 + (parts.minute ?? 0) >= time.hour * 60 + time.minute
        else { return false }
        return dismissedWeek != Self.isoWeek(now, timeZone: timeZone)
    }
}
#endif
