#if !APPSTORE
import Foundation

/// The day pills (declared in PillCatalog), their one-time switch-on and their settings.
/// Pure, tested by scripts/test-day.sh.
enum DayPills {
    static let meeting = "integration_meeting"
    static let timesheet = "integration_timesheet"
    static let all = [meeting, timesheet]

    /// The pills already switched on once: one turned off by the user stays off.
    static let seededKey = "day.seededPills"

    static func contains(_ id: String) -> Bool { all.contains(id) }

    /// The saved pill choice with the day pills it has never seen switched on, written
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
