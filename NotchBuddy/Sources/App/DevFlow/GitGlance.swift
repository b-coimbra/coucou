#if !APPSTORE
import Foundation

// MARK: - Git (parsing and repository lookup, tested by scripts/test-devflow.sh)

/// What the branch glance shows of a repository.
struct GitRepoSnapshot: Equatable, Sendable {
    var path: String
    /// The branch, or the short commit id when `detached`.
    var branch: String
    var detached: Bool
    /// Changed and untracked entries; nil when git couldn't say.
    var dirty: Int?
    /// Commits against the upstream; both nil without one.
    var ahead: Int?
    var behind: Int?

    var name: String { (path as NSString).lastPathComponent }
}

enum GitGlance {
    /// The entries of `git status --porcelain`: one line each, renames included.
    static func dirtyCount(porcelain: String) -> Int {
        porcelain.split(whereSeparator: \.isNewline)
            .filter { $0.count > 3 && !$0.hasPrefix("##") && !$0.hasPrefix("!!") }
            .count
    }

    /// `git rev-list --left-right --count @{u}...HEAD` prints "<behind> <ahead>": the left
    /// side is the upstream's commits that HEAD lacks.
    static func aheadBehind(_ output: String) -> (ahead: Int, behind: Int)? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let behind = Int(fields[0]), let ahead = Int(fields[1]),
              behind >= 0, ahead >= 0 else { return nil }
        return (ahead, behind)
    }

    /// A read-only git call on `repo`: it never writes the index (which would also make the
    /// repository look recently used) nor runs a file-system monitor set in its config.
    static func arguments(repo: String, _ command: [String]) -> [String] {
        ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", repo] + command
    }
}

/// Finds the repositories under the configured folder, without running git.
enum RepoScan {
    private static let worktreesSuffix = ".worktrees"

    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        let text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home + String(text.dropFirst(1)) }
        return text
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The git directory of a working copy: its `.git` folder, or where its `.git` file
    /// points (worktrees, submodules). nil when `repo` isn't a working copy.
    static func gitDirectory(of repo: String) -> String? {
        let dotGit = (repo as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              text.hasPrefix("gitdir:") else { return nil }
        let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("/") { return target }
        return ((repo as NSString).appendingPathComponent(target) as NSString).standardizingPath
    }

    /// The working copies one level under `root`, plus those inside its `*.worktrees` folders.
    static func repositories(under root: String) -> [String] {
        func children(_ folder: String) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted()
                .map { (folder as NSString).appendingPathComponent($0) }
        }
        var found: [String] = []
        for child in children(canonical(root)) {
            if child.hasSuffix(worktreesSuffix) {
                found += children(child).filter { gitDirectory(of: $0) != nil }
            }
            if gitDirectory(of: child) != nil { found.append(child) }
        }
        return found
    }

    /// When the repository was last worked on, as git records it: a commit, a checkout, a
    /// staged change.
    static func lastActivity(of repo: String) -> Date? {
        guard let git = gitDirectory(of: repo) else { return nil }
        return ["index", "HEAD", "logs/HEAD"].compactMap { file -> Date? in
            let path = (git as NSString).appendingPathComponent(file)
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }

    static func mostRecent(_ repos: [String]) -> String? {
        repos.compactMap { repo in lastActivity(of: repo).map { (repo: repo, date: $0) } }
            .max { $0.date < $1.date }?.repo
    }

    /// The repository holding `path` (the deepest one).
    static func repository(containing path: String, in repos: [String]) -> String? {
        let target = canonical(path)
        return repos.filter { target == $0 || target.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    /// The repositories a window title names: editors and terminals put the folder's name or
    /// path between dashes ("● main.swift — coucou").
    static func repositories(namedBy title: String, in repos: [String],
                             home: String = NSHomeDirectory()) -> [String] {
        var parts = [title]
        for separator in [" — ", " – ", " - ", " · "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var found: [String] = []
        for raw in parts {
            var part = raw.trimmingCharacters(in: .whitespaces)
            for mark in ["● ", "• ", "* "] where part.hasPrefix(mark) { part.removeFirst(mark.count) }
            // "repo [SSH: host]", "repo (Workspace)"
            for opening in [" [", " ("] {
                if let range = part.range(of: opening) { part = String(part[..<range.lowerBound]) }
            }
            guard !part.isEmpty else { continue }
            if part.hasPrefix("/") || part.hasPrefix("~/") {
                if let repo = repository(containing: expand(part, home: home), in: repos) { found.append(repo) }
            } else {
                found += repos.filter { ($0 as NSString).lastPathComponent == part }
            }
        }
        return found
    }

    /// The repository an editor or terminal window shows: from its document (a file URL),
    /// else from its title. nil when neither names a known repository.
    static func repository(forDocument document: String?, title: String?, in repos: [String],
                           home: String = NSHomeDirectory()) -> String? {
        if let document, let url = URL(string: document), url.isFileURL,
           let repo = repository(containing: url.path, in: repos) {
            return repo
        }
        guard let title else { return nil }
        // Several repositories can share a folder name (worktrees): the one used last.
        let named = repositories(namedBy: title, in: repos, home: home)
        return mostRecent(named) ?? named.first
    }
}
#endif
