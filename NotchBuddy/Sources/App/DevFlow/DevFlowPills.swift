#if !APPSTORE
import Foundation

/// The dev flow pills (declared in PillCatalog) and their one-time switch-on.
/// Pure, tested by scripts/test-devflow.sh.
enum DevFlowPills {
    static let jira = "integration_jira"
    static let pullRequests = "integration_prs"
    static let reviews = "integration_reviews"
    static let branch = "integration_branch"
    static let all = [jira, pullRequests, reviews, branch]

    /// The pills already switched on once: one turned off by the user stays off.
    static let seededKey = "devFlow.seededPills"

    static func contains(_ id: String) -> Bool { all.contains(id) }

    /// The saved pill choice with the dev flow pills it has never seen switched on, written
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
