#if !APPSTORE
import Foundation

// MARK: - Jira (pure, tested by scripts/test-devflow.sh)

/// An issue as the Jira card shows it. Display only.
struct JiraIssue: Equatable, Sendable {
    /// Jira's own grouping of statuses: gives the status its colour.
    enum Category: Equatable, Sendable { case toDo, inProgress, done, unknown }

    let key: String
    let summary: String
    let status: String
    let category: Category

    /// A `GET /rest/api/3/issue/<KEY>?fields=status,summary` answer.
    static func decode(_ data: Data) -> JiraIssue? {
        struct Answer: Decodable {
            struct Fields: Decodable {
                struct Status: Decodable {
                    struct Category: Decodable { let key: String? }
                    let name: String?
                    let statusCategory: Category?
                }
                let summary: String?
                let status: Status?
            }
            let key: String
            let fields: Fields
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let status = answer.fields.status?.name else { return nil }
        let category: Category
        switch answer.fields.status?.statusCategory?.key {
        case "new":           category = .toDo
        case "indeterminate": category = .inProgress
        case "done":          category = .done
        default:              category = .unknown
        }
        return JiraIssue(key: answer.key, summary: answer.fields.summary ?? "",
                         status: status, category: category)
    }
}

enum JiraIssueKey {
    static let defaultPrefix = "POC"
    static let defaultSite = "https://medcof.atlassian.net"

    /// A Jira project key: a letter, then letters or digits. Anything else reads as the default.
    static func prefix(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let first = text.first, first.isASCII, first.isLetter, text.count <= 20,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return defaultPrefix }
        return text
    }

    /// The first `<PREFIX>-<number>` of a branch name, upper-cased. The key must stand on
    /// its own: "XPOC-1" and "POC-12a" are not keys.
    static func parse(branch: String, prefix raw: String = defaultPrefix) -> String? {
        let project = prefix(raw)
        let pattern = "(?<![A-Za-z0-9])\(project)-([0-9]+)(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)),
              let digits = Range(match.range(at: 1), in: branch) else { return nil }
        return "\(project)-\(branch[digits])"
    }

    /// Whether `key` is a whole upper-case issue key, safe to put in a URL path.
    static func isKey(_ key: String) -> Bool {
        key.range(of: "^[A-Z][A-Z0-9]*-[0-9]+$", options: .regularExpression) != nil
    }

    /// The configured Jira site: https only (the API token is sent there), without user,
    /// query or fragment. Empty reads as the default; anything else invalid is nil.
    static func site(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text.isEmpty ? defaultSite : text),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = "https"
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    /// The issue's page.
    static func browseURL(site raw: String, key: String) -> URL? {
        guard isKey(key), let base = site(raw) else { return nil }
        return base.appendingPathComponent("browse").appendingPathComponent(key)
    }

    /// The REST call for the issue's status and summary.
    static func apiURL(site raw: String, key: String) -> URL? {
        guard isKey(key), let base = site(raw),
              var parts = URLComponents(url: base.appendingPathComponent("rest/api/3/issue/\(key)"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "fields", value: "status,summary")]
        return parts.url
    }

    /// Jira Cloud's basic authentication: the account's email and an API token.
    static func authorization(email: String, token: String) -> String {
        "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }
}
#endif
