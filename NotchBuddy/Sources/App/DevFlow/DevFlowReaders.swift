#if !APPSTORE
import ApplicationServices
import Foundation

// MARK: - Cancellation

/// Set when a feature is switched off: a read in progress starts no further tool.
final class DevCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - GitHub, through the gh CLI

enum GHFailure: Equatable, Sendable { case missing, failed }

struct GHFetch: Sendable {
    struct Mine: Sendable {
        let summary: PRSummary
        /// nil when this one couldn't be read.
        let detail: PRDetail?
    }
    /// nil when not asked for, or when a search failed (what was shown stays).
    var mine: [Mine]?
    var reviews: [PRSummary]?
    var failure: GHFailure?
}

/// Reads pull requests with `gh`, signed in by the user: Coucou holds no token for it.
/// Blocking: called off the main thread.
enum GHClient {
    private static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    static func fetch(mine: Bool, reviews: Bool, cancellation: DevCancellation) -> GHFetch {
        var result = GHFetch()
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            result.failure = .missing
            return result
        }
        if mine, let found = search(gh, .author, cancellation) {
            result.mine = found.map { summary in
                let output = run(gh, PRScope.view(summary.ref), cancellation)
                return GHFetch.Mine(summary: summary,
                                    detail: output.flatMap { GHDecode.detail($0, author: summary.author) })
            }
        } else if mine {
            result.failure = .failed
        }
        if reviews, let found = search(gh, .reviewRequested, cancellation) {
            result.reviews = PRScope.oldestFirst(found)
        } else if reviews {
            result.failure = .failed
        }
        return result
    }

    /// nil when either search fails: half a list would look like closed pull requests.
    private static func search(_ gh: String, _ role: PRScope.Role,
                               _ cancellation: DevCancellation) -> [PRSummary]? {
        var lists: [[PRSummary]] = []
        for arguments in PRScope.searches(role) {
            guard let output = run(gh, arguments, cancellation),
                  let list = GHDecode.search(output) else { return nil }
            lists.append(list)
        }
        return PRScope.merge(lists)
    }

    private static func run(_ gh: String, _ arguments: [String], _ cancellation: DevCancellation) -> Data? {
        guard !cancellation.isCancelled else { return nil }
        var environment = ProcessInfo.processInfo.environment
        // The app doesn't get the shell's PATH.
        environment["PATH"] = [(gh as NSString).deletingLastPathComponent, "/usr/bin", "/bin",
                               environment["PATH"] ?? ""].joined(separator: ":")
        environment["GH_HOST"] = "github.com"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: "GH_DEBUG")
        guard let result = DevProcess.run(gh, arguments, environment: environment, timeout: 20),
              result.succeeded else { return nil }
        return result.stdout
    }
}

// MARK: - The active repository

/// The app in front, when it may be showing a repository.
struct FrontApp: Sendable {
    let bundleId: String
    let pid: pid_t
}

struct RepoReading: Sendable {
    var snapshot: GitRepoSnapshot?
    /// The editor or terminal the repository was found in, if it was.
    var editorBundleId: String?
}

/// Finds the active repository and reads it with git. Used from one serial queue only
/// (RepoWatcher's), which guards the cache.
final class RepoReader: @unchecked Sendable {
    private var cache: (root: String, repos: [String], at: Date)?

    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.codium",
        "com.todesktop.230313mzl4w4u92", "com.google.antigravity", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "org.alacritty", "dev.warp.Warp-Stable",
    ]

    func forgetRepositories() { cache = nil }

    /// The pinned repository, else the one in the front editor or terminal, else the one
    /// worked on last under the configured folder.
    func read(root: String, pinned: String, front: FrontApp?) -> RepoReading {
        if !pinned.isEmpty {
            let top = git(RepoScan.expand(pinned), ["rev-parse", "--show-toplevel"])
            return RepoReading(snapshot: top.flatMap { snapshot(of: $0) })
        }
        let repos = repositories(under: RepoScan.expand(root))
        if let front, Self.editors.contains(front.bundleId) {
            let window = Self.focusedWindow(of: front.pid)
            if let repo = RepoScan.repository(forDocument: window.document, title: window.title, in: repos) {
                return RepoReading(snapshot: snapshot(of: repo), editorBundleId: front.bundleId)
            }
        }
        return RepoReading(snapshot: RepoScan.mostRecent(repos).flatMap { snapshot(of: $0) })
    }

    /// The folder listing is kept five minutes.
    private func repositories(under root: String) -> [String] {
        if let cache, cache.root == root, Date().timeIntervalSince(cache.at) < 300 { return cache.repos }
        let repos = RepoScan.repositories(under: root)
        cache = (root, repos, Date())
        return repos
    }

    /// The front window's document and title. Only when Accessibility is already allowed:
    /// nothing here ever asks for it.
    private static func focusedWindow(of pid: pid_t) -> (document: String?, title: String?) {
        guard AXIsProcessTrusted() else { return (nil, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return (nil, nil) }
        // swiftlint:disable force_cast
        let window = windowRef as! AXUIElement
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        return (string(kAXDocumentAttribute), string(kAXTitleAttribute))
    }

    private func snapshot(of repo: String) -> GitRepoSnapshot? {
        var branch = git(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        let detached = branch == nil
        if detached { branch = git(repo, ["rev-parse", "--short", "HEAD"]) }
        guard let branch else { return nil }
        let dirty = gitOutput(repo, ["status", "--porcelain"]).map { GitGlance.dirtyCount(porcelain: $0) }
        let distance = git(repo, ["rev-list", "--left-right", "--count", "@{u}...HEAD"])
            .flatMap { GitGlance.aheadBehind($0) }
        return GitRepoSnapshot(path: repo, branch: branch, detached: detached, dirty: dirty,
                               ahead: distance?.ahead, behind: distance?.behind)
    }

    /// The first line of a command's answer; nil when it fails or says nothing.
    private func git(_ repo: String, _ command: [String]) -> String? {
        let line = gitOutput(repo, command)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return line?.isEmpty == false ? line : nil
    }

    private func gitOutput(_ repo: String, _ command: [String]) -> String? {
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        guard let result = DevProcess.run("/usr/bin/git", GitGlance.arguments(repo: repo, command),
                                          environment: environment, timeout: 8),
              result.succeeded else { return nil }
        return result.text
    }
}

// MARK: - Jira

/// What the Jira card knows about the current key.
enum JiraState: Equatable, Sendable {
    case noCredentials, badSite, loading, unauthorized, notFound, unreachable
    case issue(JiraIssue)
}

/// The one call to Jira: an issue's status and summary. The token goes to the configured
/// https site only and is never logged.
enum JiraClient {
    /// Nothing cached on disk.
    private static let session = URLSession(configuration: .ephemeral)

    /// A redirect is refused, so the credentials never follow it elsewhere.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func fetch(_ url: URL, authorization: String) async -> JiraState {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request, delegate: NoRedirect()),
              let code = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        switch code {
        case 200:      return JiraIssue.decode(data).map { .issue($0) } ?? .unreachable
        case 401, 403: return .unauthorized
        case 404:      return .notFound
        default:       return .unreachable
        }
    }
}
#endif
