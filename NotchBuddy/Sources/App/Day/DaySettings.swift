#if !APPSTORE
import Foundation

/// The day features' own settings. The two pills are switched on and off like any pill
/// (AppState.activeIntegrations); Do not disturb is Edge Light's own switch.
enum DaySettings {
    static let focusFilterKey = "day.focusFilter"
    static let timesheetWeekdayKey = "day.timesheet.weekday"
    static let timesheetTimeKey = "day.timesheet.time"
    /// The ISO week ("2026-W48") whose reminder was dismissed: all that is kept.
    static let timesheetDismissedKey = "day.timesheet.dismissedWeek"

    /// On until turned off.
    static var focusFilter: Bool { UserDefaults.standard.object(forKey: focusFilterKey) as? Bool ?? true }

    static var timesheet: TimesheetSchedule {
        let defaults = UserDefaults.standard
        let weekday = defaults.object(forKey: timesheetWeekdayKey) as? Int
        let time = DailyResetTime(defaults.string(forKey: timesheetTimeKey) ?? "")
        return TimesheetSchedule(weekday: weekday ?? TimesheetSchedule.fallbackWeekday,
                                 time: time ?? TimesheetSchedule.fallbackTime)
    }
}
#endif
