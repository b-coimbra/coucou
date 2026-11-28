#if !APPSTORE
import Foundation

/// The dev flow's own settings. The four pills are switched on and off like any pill
/// (AppState.activeIntegrations); the Jira token lives only in the Keychain.
enum DevFlowSettings {
    static let ciAlertKey = "devFlow.ciAlert"
    static let jiraSiteKey = "devFlow.jiraSite"
    static let jiraPrefixKey = "devFlow.jiraPrefix"
    static let reposRootKey = "devFlow.reposRoot"
    static let pinnedRepoKey = "devFlow.pinnedRepo"
    static let prSeenKey = "devFlow.prSeen"
    static let defaultReposRoot = "~/dev"
    static let jiraEmailKeychainKey = "jira-email"
    static let jiraTokenKeychainKey = "jira-api-token"

    private static func text(_ key: String, _ fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    /// On until turned off.
    static var ciAlert: Bool { UserDefaults.standard.object(forKey: ciAlertKey) as? Bool ?? true }
    static var jiraSite: String { text(jiraSiteKey, JiraIssueKey.defaultSite) }
    static var jiraPrefix: String { JiraIssueKey.prefix(text(jiraPrefixKey, JiraIssueKey.defaultPrefix)) }
    static var reposRoot: String { text(reposRootKey, defaultReposRoot) }
    static var pinnedRepo: String { text(pinnedRepoKey, "") }
}
#endif
