#if !APPSTORE
import Foundation

/// The agent pills (declared in PillCatalog), their one-time switch-on and the notice they
/// show in the notch. Pure, tested by scripts/test-agents.sh.
enum AgentPills {
    static let usageReset = "integration_usage_reset"
    static let claudeJobs = "integration_claude_jobs"
    static let all = [usageReset, claudeJobs]

    /// The pills already switched on once: one turned off by the user stays off.
    static let seededKey = "agents.seededPills"

    static func contains(_ id: String) -> Bool { all.contains(id) }

    /// The saved pill choice with the agent pills it has never seen switched on, written
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

/// The agents' own settings. The two pills are switched on and off like any pill
/// (AppState.activeIntegrations).
enum AgentSettings {
    /// "18:30": the daily reset assumed while Claude Code has given no reset time.
    static let resetTimeKey = "agents.resetTime"
    static let cursorPingKey = "agents.cursorPing"

    static var resetTime: DailyResetTime {
        DailyResetTime(UserDefaults.standard.string(forKey: resetTimeKey) ?? "") ?? .fallback
    }

    /// On until turned off.
    static var cursorPing: Bool { UserDefaults.standard.object(forKey: cursorPingKey) as? Bool ?? true }
}

/// What an agent feature shows on the notch's notice card. In memory only.
struct AgentNotice: Sendable, Equatable {
    enum Kind: Sendable { case jobFinished, cursorNeedsInput }

    let pillId: String
    let kind: Kind
    let text: String
    /// How many things the notice stands for
    var count = 1
    /// The folder a finished job ran in, shown in the Finder on a click
    var folderPath: String? = nil
}
#endif
