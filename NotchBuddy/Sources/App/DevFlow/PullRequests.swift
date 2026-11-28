#if !APPSTORE
import Foundation

// MARK: - Pull requests (gh JSON, CI states, "new since seen"; tested by scripts/test-devflow.sh)

/// A pull request by its structured fields. Its web address is built from them, never taken
/// from fetched text.
struct PRRef: Equatable, Hashable, Sendable {
    /// "owner/name"
    let repo: String
    let number: Int

    /// nil unless `repo` is a plain "owner/name" and `number` is positive.
    init?(repo: String, number: Int) {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard number > 0, parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix("-")
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }) else { return nil }
        self.repo = repo
        self.number = number
    }

    var id: String { "\(repo)#\(number)" }
    var shortName: String { "\(repo.split(separator: "/").last ?? "")#\(number)" }
    var url: URL? { URL(string: "https://github.com/\(repo)/pull/\(number)") }
}

/// What the checks of a pull request say.
enum PRCheckState: String, Equatable, Sendable {
    case passing, failing, running, noChecks
}

/// A pull request found by a search.
struct PRSummary: Equatable, Sendable, Identifiable {
    let ref: PRRef
    let title: String
    let author: String
    let createdAt: Date
    let isDraft: Bool
    var id: String { ref.id }
}

/// What `gh pr view` adds: the checks, and what others wrote.
struct PRDetail: Equatable, Sendable {
    let checks: PRCheckState
    /// Reviews and comments by anyone but the author.
    let activityCount: Int
    let latestActivity: Date?
}

/// A row of the "My PRs" card.
struct PRRow: Equatable, Sendable, Identifiable {
    var summary: PRSummary
    var detail: PRDetail?
    /// A review or comment arrived since the row was last seen.
    var unseen = false
    var id: String { summary.id }
}

/// One entry of `statusCheckRollup`: a check run (status, conclusion) or a commit status
/// (context, state).
struct GHCheck: Decodable, Equatable, Sendable {
    var name: String?
    var workflowName: String?
    var context: String?
    var status: String?
    var conclusion: String?
    var state: String?
    var startedAt: String?
}

enum PRChecks {
    private static let failedConclusions: Set<String> = [
        "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "CANCELLED",
    ]

    /// Running while anything runs (the result isn't in yet), then failing if anything
    /// failed. Only the latest run of each check counts.
    static func state(of checks: [GHCheck]) -> PRCheckState {
        // A run with no start time hasn't started: it is the newest of its check.
        func start(_ check: GHCheck) -> String {
            guard let at = check.startedAt, !at.isEmpty, !at.hasPrefix("0001-") else { return "~" }
            return at
        }
        var latest: [String: GHCheck] = [:]
        for check in checks {
            let key = check.context.map { "status:\($0)" }
                ?? "run:\(check.workflowName ?? "")/\(check.name ?? "")"
            if let old = latest[key], start(old) > start(check) { continue }
            latest[key] = check
        }
        guard !latest.isEmpty else { return .noChecks }

        var failed = false
        for check in latest.values {
            if check.context != nil {
                let state = check.state?.uppercased() ?? ""
                if state == "PENDING" || state == "EXPECTED" { return .running }
                if state == "FAILURE" || state == "ERROR" { failed = true }
            } else {
                if check.status?.uppercased() != "COMPLETED" { return .running }
                if failedConclusions.contains(check.conclusion?.uppercased() ?? "") { failed = true }
            }
        }
        return failed ? .failing : .passing
    }
}

/// A pull request whose checks just finished.
struct CITransition: Equatable, Sendable {
    let id: String
    let passed: Bool

    /// From running to passing or failing. A pull request seen for the first time says
    /// nothing: no alert on the first poll.
    static func between(previous: [String: PRCheckState], current: [String: PRCheckState]) -> [CITransition] {
        current.keys.sorted().compactMap { id in
            guard previous[id] == .running else { return nil }
            switch current[id] {
            case .passing?: return CITransition(id: id, passed: true)
            case .failing?: return CITransition(id: id, passed: false)
            default:        return nil
            }
        }
    }
}

/// Which pull requests have a review or comment not seen yet. Times are seconds since 1970,
/// 0 for none.
enum PRSeen {
    /// - saved: what was seen, by pull request id; nil the very first time, when everything
    ///   already there counts as seen.
    /// - latest: the newest activity of the pull requests that could be read.
    /// - open: every open pull request; the others are forgotten.
    static func update(saved: [String: Double]?, latest: [String: Double],
                       open: Set<String>) -> (seen: [String: Double], unseen: Set<String>) {
        var seen = (saved ?? latest).filter { open.contains($0.key) }
        var unseen: Set<String> = []
        for (id, time) in latest where open.contains(id) {
            let before = seen[id] ?? 0
            seen[id] = before
            if time > before { unseen.insert(id) }
        }
        return (seen, unseen)
    }
}

/// The pull requests watched, and the gh calls that read them (argument arrays, no shell).
enum PRScope {
    static let organization = "MedCof-Tech"
    static let repository = "b-coimbra/coucou"

    enum Role: Sendable { case author, reviewRequested }

    /// One search for the organization, one for the repository.
    static func searches(_ role: Role) -> [[String]] {
        let who: [String]
        switch role {
        case .author:          who = ["--author", "@me", "--sort", "updated", "--order", "desc"]
        case .reviewRequested: who = ["--review-requested", "@me", "--sort", "created", "--order", "asc"]
        }
        return [["--owner", organization], ["--repo", repository]].map { scope in
            ["search", "prs"] + who + ["--state", "open"] + scope
                + ["--limit", "50", "--json", "number,title,repository,author,createdAt,isDraft"]
        }
    }

    static func view(_ ref: PRRef) -> [String] {
        ["pr", "view", String(ref.number), "-R", ref.repo, "--json", "statusCheckRollup,reviews,comments"]
    }

    /// The results of both searches, without duplicates.
    static func merge(_ lists: [[PRSummary]]) -> [PRSummary] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    static func oldestFirst(_ list: [PRSummary]) -> [PRSummary] {
        list.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}

enum GHDecode {
    private struct Author: Decodable { let login: String? }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `gh search prs --json number,title,repository,author,createdAt,isDraft`
    static func search(_ data: Data) -> [PRSummary]? {
        struct Item: Decodable {
            struct Repository: Decodable { let nameWithOwner: String }
            let number: Int
            let title: String
            let repository: Repository
            let author: Author?
            let createdAt: Date
            let isDraft: Bool?
        }
        guard let items = try? decoder.decode([Item].self, from: data) else { return nil }
        return items.compactMap { item in
            guard let ref = PRRef(repo: item.repository.nameWithOwner, number: item.number) else { return nil }
            return PRSummary(ref: ref, title: item.title, author: item.author?.login ?? "",
                             createdAt: item.createdAt, isDraft: item.isDraft ?? false)
        }
    }

    /// `gh pr view --json statusCheckRollup,reviews,comments`. `author` is the pull request's
    /// own: what they write isn't news to them. A review not submitted yet doesn't count.
    static func detail(_ data: Data, author: String) -> PRDetail? {
        struct Activity: Decodable {
            let author: Author?
            let state: String?
            let createdAt: Date?
            let submittedAt: Date?
        }
        struct View: Decodable {
            let statusCheckRollup: [GHCheck]?
            let reviews: [Activity]
            let comments: [Activity]
        }
        guard let view = try? decoder.decode(View.self, from: data) else { return nil }
        let others = (view.reviews + view.comments).filter { activity in
            guard activity.state?.uppercased() != "PENDING" else { return false }
            return (activity.author?.login ?? "").caseInsensitiveCompare(author) != .orderedSame
        }
        return PRDetail(checks: PRChecks.state(of: view.statusCheckRollup ?? []),
                        activityCount: others.count,
                        latestActivity: others.compactMap { $0.submittedAt ?? $0.createdAt }.max())
    }
}
#endif
