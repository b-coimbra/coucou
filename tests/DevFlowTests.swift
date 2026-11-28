import Foundation

// Pure logic of the dev flow (Jira card, pull requests, CI alert, review requests, branch
// glance). All data is synthetic; no git, gh or network call. Run: scripts/test-devflow.sh

@main
enum DevFlowTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func section(_ name: String) { print(name) }

    static func main() {
        jiraKeys()
        jiraSite()
        jiraIssue()
        gitParsing()
        repositories()
        pullRequestReferences()
        ghDecoding()
        checkStates()
        transitions()
        seen()
        scope()
        pills()
        process()

        if failures > 0 {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
        print("\nAll tests passed.")
    }

    // MARK: - Jira

    static func jiraKeys() {
        section("JiraIssueKey.parse")
        func key(_ branch: String, _ prefix: String = "POC") -> String? {
            JiraIssueKey.parse(branch: branch, prefix: prefix)
        }
        check("feat/POC-1203-login", key("feat/POC-1203-login") == "POC-1203")
        check("poc-844 is upper-cased", key("poc-844") == "POC-844")
        check("main → nil", key("main") == nil)
        check("POC-12a is not a key", key("POC-12a") == nil)
        check("XPOC-12 is not a key", key("XPOC-12") == nil)
        check("POC- without a number → nil", key("feat/POC-login") == nil)
        check("POC_12 → nil", key("POC_12") == nil)
        check("underscore after the number", key("POC-12_login") == "POC-12")
        check("the first key wins", key("fix/poc-7/POC-8") == "POC-7")
        check("a later key after a non-key", key("POC-12a-then-POC-13") == "POC-13")
        check("another prefix", key("abc-5-thing", "ABC") == "ABC-5")
        check("lower-case prefix setting", key("ABC-5", "abc") == "ABC-5")
        check("another project is ignored", key("ABC-5") == nil)
        check("a prefix that is a pattern reads as the default", key("POC-3", ".*") == "POC-3")
        check("empty prefix reads as the default", JiraIssueKey.prefix("  ") == "POC")
    }

    static func jiraSite() {
        section("Jira URLs")
        check("browse on the default site",
              JiraIssueKey.browseURL(site: JiraIssueKey.defaultSite, key: "POC-1")?.absoluteString
                == "https://medcof.atlassian.net/browse/POC-1")
        check("empty site reads as the default",
              JiraIssueKey.site("")?.absoluteString == "https://medcof.atlassian.net")
        check("trailing slash dropped",
              JiraIssueKey.browseURL(site: "https://example.atlassian.net/", key: "ABC-2")?.absoluteString
                == "https://example.atlassian.net/browse/ABC-2")
        check("http refused", JiraIssueKey.site("http://example.atlassian.net") == nil)
        check("no scheme refused", JiraIssueKey.site("example.atlassian.net") == nil)
        check("user in the URL refused", JiraIssueKey.site("https://me@example.atlassian.net") == nil)
        check("query refused", JiraIssueKey.site("https://example.atlassian.net?x=1") == nil)
        check("a key with a path is refused",
              JiraIssueKey.browseURL(site: "", key: "POC-1/../../x") == nil)
        check("REST call",
              JiraIssueKey.apiURL(site: "", key: "POC-1")?.absoluteString
                == "https://medcof.atlassian.net/rest/api/3/issue/POC-1?fields=status,summary")
        check("basic authorization",
              JiraIssueKey.authorization(email: "a@example.com", token: "synthetic")
                == "Basic " + Data("a@example.com:synthetic".utf8).base64EncodedString())
    }

    static func jiraIssue() {
        section("JiraIssue.decode")
        let json = """
        {"key":"POC-1","fields":{"summary":"Synthetic summary",
         "status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}
        """
        let issue = JiraIssue.decode(Data(json.utf8))
        check("key, summary, status", issue?.key == "POC-1" && issue?.summary == "Synthetic summary"
              && issue?.status == "In Progress")
        check("category", issue?.category == .inProgress)
        check("an error answer → nil", JiraIssue.decode(Data(#"{"errorMessages":["x"]}"#.utf8)) == nil)
    }

    // MARK: - Git

    static func gitParsing() {
        section("GitGlance")
        let porcelain = " M a.swift\nA  b.swift\nR  old.swift -> new.swift\n?? folder/\nUU c.swift\n"
        check("5 entries", GitGlance.dirtyCount(porcelain: porcelain) == 5)
        check("clean", GitGlance.dirtyCount(porcelain: "") == 0)
        check("branch and ignored lines don't count",
              GitGlance.dirtyCount(porcelain: "## main...origin/main\n!! build/\n M a\n") == 1)
        let distance = GitGlance.aheadBehind("2\t3\n")
        check("left is behind, right is ahead", distance?.ahead == 3 && distance?.behind == 2)
        check("in sync", GitGlance.aheadBehind("0\t0")?.ahead == 0)
        check("empty → nil", GitGlance.aheadBehind("") == nil)
        check("an error message → nil", GitGlance.aheadBehind("fatal: no upstream") == nil)
        check("one number → nil", GitGlance.aheadBehind("3") == nil)
        let arguments = GitGlance.arguments(repo: "/tmp/a b", ["status", "--porcelain"])
        check("never writes the index", arguments.first == "--no-optional-locks")
        check("the path is one argument", arguments.contains("/tmp/a b"))
    }

    static func repositories() {
        section("RepoScan")
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("coucou-devflow-\(UUID().uuidString)")
        try? fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.resolvingSymlinksInPath().path

        func folder(_ path: String) -> String {
            let full = root + "/" + path
            try? fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            return full
        }
        func write(_ path: String, _ text: String, at date: Date) {
            fm.createFile(atPath: root + "/" + path, contents: Data(text.utf8))
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: root + "/" + path)
        }
        let old = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let newest = Date(timeIntervalSince1970: 3_000_000)

        let app = folder("app")
        _ = folder("app/.git")
        write("app/.git/HEAD", "ref: refs/heads/main", at: old)
        _ = folder("app/vendor/inner/.git")
        let worktree = folder("app.worktrees/feature")
        _ = folder("app/.git/worktrees/feature")
        write("app/.git/worktrees/feature/HEAD", "ref: refs/heads/feature", at: newest)
        write("app.worktrees/feature/.git", "gitdir: \(app)/.git/worktrees/feature\n", at: old)
        let site = folder("site")
        _ = folder("site/.git")
        write("site/.git/index", "", at: newer)
        _ = folder("notes")
        _ = folder("group/deeper/.git")

        let repos = RepoScan.repositories(under: root)
        check("one level plus *.worktrees", Set(repos) == Set([app, worktree, site]))
        check("relative gitdir resolved", {
            _ = folder("relative.worktrees/one")
            write("relative.worktrees/one/.git", "gitdir: ../../app/.git/worktrees/feature", at: old)
            return RepoScan.gitDirectory(of: root + "/relative.worktrees/one")
                == app + "/.git/worktrees/feature"
        }())
        check("a folder without .git", RepoScan.gitDirectory(of: root + "/notes") == nil)
        check("most recent follows the worktree's git directory", RepoScan.mostRecent(repos) == worktree)
        check("most recent of the others", RepoScan.mostRecent([app, site]) == site)
        check("nothing → nil", RepoScan.mostRecent([]) == nil)

        check("containing", RepoScan.repository(containing: app + "/Sources/a.swift", in: repos) == app)
        check("a folder with a longer name is not inside",
              RepoScan.repository(containing: root + "/apple/a", in: repos) == nil)

        check("editor title",
              RepoScan.repository(forDocument: nil, title: "● main.swift — site", in: repos) == site)
        check("terminal title",
              RepoScan.repository(forDocument: nil, title: "app — -zsh — 80×24", in: repos) == app)
        check("remote suffix dropped",
              RepoScan.repository(forDocument: nil, title: "a.ts - site [SSH: box]", in: repos) == site)
        check("path in a title, from the home folder",
              RepoScan.repository(forDocument: nil, title: "~/site/src", in: repos, home: root) == site)
        check("the document wins over the title",
              RepoScan.repository(forDocument: "file://\(app)/a.swift", title: "x — site", in: repos) == app)
        check("a document outside every repository falls back to the title",
              RepoScan.repository(forDocument: "file:///etc/hosts", title: "x — site", in: repos) == site)
        check("a web document is ignored",
              RepoScan.repository(forDocument: "https://example.com", title: "Inbox", in: repos) == nil)
        check("~ expands", RepoScan.expand("~/dev", home: "/Users/x") == "/Users/x/dev")
    }

    // MARK: - Pull requests

    static func pullRequestReferences() {
        section("PRRef")
        let ref = PRRef(repo: "MedCof-Tech/api.service_v2", number: 42)
        check("URL from the fields",
              ref?.url?.absoluteString == "https://github.com/MedCof-Tech/api.service_v2/pull/42")
        check("short name", ref?.shortName == "api.service_v2#42")
        check("three parts refused", PRRef(repo: "a/b/c", number: 1) == nil)
        check("dot-dot refused", PRRef(repo: "a/..", number: 1) == nil)
        check("a flag-like owner refused", PRRef(repo: "-R/b", number: 1) == nil)
        check("query refused", PRRef(repo: "a/b?x=1", number: 1) == nil)
        check("space refused", PRRef(repo: "a/b c", number: 1) == nil)
        check("empty name refused", PRRef(repo: "a/", number: 1) == nil)
        check("number 0 refused", PRRef(repo: "a/b", number: 0) == nil)
    }

    static func ghDecoding() {
        section("GHDecode")
        let search = """
        [{"number":7,"title":"Synthetic","isDraft":true,"createdAt":"2026-01-02T10:00:00Z",
          "repository":{"name":"api","nameWithOwner":"MedCof-Tech/api"},
          "author":{"login":"someone","is_bot":false}},
         {"number":8,"title":"Bad repository","isDraft":false,"createdAt":"2026-01-02T10:00:00Z",
          "repository":{"name":"x","nameWithOwner":"not a repository"},"author":{"login":"someone"}}]
        """
        let found = GHDecode.search(Data(search.utf8))
        check("one valid result", found?.count == 1)
        check("fields", found?.first?.ref.id == "MedCof-Tech/api#7" && found?.first?.isDraft == true
              && found?.first?.author == "someone")
        check("empty list", GHDecode.search(Data("[]".utf8)) == [])
        check("an error text → nil", GHDecode.search(Data("HTTP 401".utf8)) == nil)

        let view = """
        {"statusCheckRollup":[
           {"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED",
            "conclusion":"SUCCESS","startedAt":"2026-01-02T10:00:00Z"},
           {"__typename":"StatusContext","context":"deploy","state":"SUCCESS",
            "startedAt":"2026-01-02T10:00:00Z"}],
         "reviews":[
           {"author":{"login":"reviewer"},"state":"COMMENTED","body":"",
            "submittedAt":"2026-01-03T10:00:00Z"},
           {"author":{"login":"Someone"},"state":"COMMENTED","submittedAt":"2026-01-09T10:00:00Z"},
           {"author":{"login":"other"},"state":"PENDING","submittedAt":null}],
         "comments":[
           {"author":{"login":"bot"},"body":"x","createdAt":"2026-01-04T10:00:00Z"},
           {"author":{"login":"someone"},"body":"mine","createdAt":"2026-01-08T10:00:00Z"}]}
        """
        let detail = GHDecode.detail(Data(view.utf8), author: "someone")
        check("checks", detail?.checks == .passing)
        check("the author's own and pending reviews don't count", detail?.activityCount == 2)
        check("latest activity by others",
              detail?.latestActivity == ISO8601DateFormatter().date(from: "2026-01-04T10:00:00Z"))
        let empty = GHDecode.detail(Data(#"{"statusCheckRollup":[],"reviews":[],"comments":[]}"#.utf8),
                                    author: "someone")
        check("nothing yet", empty == PRDetail(checks: .noChecks, activityCount: 0, latestActivity: nil))
        check("a null rollup",
              GHDecode.detail(Data(#"{"statusCheckRollup":null,"reviews":[],"comments":[]}"#.utf8),
                              author: "a")?.checks == .noChecks)
        check("garbage → nil", GHDecode.detail(Data("{}".utf8), author: "a") == nil)
    }

    static func checkStates() {
        section("PRChecks.state")
        func run(_ name: String, _ status: String, _ conclusion: String = "",
                 at: String? = "2026-01-01T10:00:00Z") -> GHCheck {
            GHCheck(name: name, workflowName: "CI", status: status, conclusion: conclusion, startedAt: at)
        }
        func context(_ name: String, _ state: String) -> GHCheck { GHCheck(context: name, state: state) }

        check("none", PRChecks.state(of: []) == .noChecks)
        check("success, skipped and neutral pass",
              PRChecks.state(of: [run("a", "COMPLETED", "SUCCESS"), run("b", "COMPLETED", "SKIPPED"),
                                  run("c", "COMPLETED", "NEUTRAL")]) == .passing)
        check("in progress", PRChecks.state(of: [run("a", "IN_PROGRESS")]) == .running)
        check("queued", PRChecks.state(of: [run("a", "QUEUED")]) == .running)
        check("failure", PRChecks.state(of: [run("a", "COMPLETED", "FAILURE")]) == .failing)
        check("timed out", PRChecks.state(of: [run("a", "COMPLETED", "TIMED_OUT")]) == .failing)
        check("still running after a failure",
              PRChecks.state(of: [run("a", "COMPLETED", "FAILURE"), run("b", "IN_PROGRESS")]) == .running)
        check("a later rerun replaces the failure",
              PRChecks.state(of: [run("a", "COMPLETED", "SUCCESS", at: "2026-01-01T11:00:00Z"),
                                  run("a", "COMPLETED", "FAILURE")]) == .passing)
        check("a queued rerun with no start time is the newest",
              PRChecks.state(of: [run("a", "QUEUED", at: "0001-01-01T00:00:00Z"),
                                  run("a", "COMPLETED", "FAILURE")]) == .running)
        check("pending status", PRChecks.state(of: [context("x", "PENDING")]) == .running)
        check("expected status", PRChecks.state(of: [context("x", "EXPECTED")]) == .running)
        check("error status", PRChecks.state(of: [context("x", "ERROR")]) == .failing)
        check("success status", PRChecks.state(of: [context("x", "SUCCESS")]) == .passing)
    }

    static func transitions() {
        section("CITransition.between")
        let previous: [String: PRCheckState] = [
            "a": .running, "b": .running, "c": .passing, "d": .failing, "e": .running, "f": .running,
            "gone": .running,
        ]
        let current: [String: PRCheckState] = [
            "b": .failing, "a": .passing, "c": .failing, "d": .passing, "e": .running, "f": .noChecks,
            "new": .passing,
        ]
        check("only running → finished, in order",
              CITransition.between(previous: previous, current: current)
                == [CITransition(id: "a", passed: true), CITransition(id: "b", passed: false)])
        check("first poll says nothing", CITransition.between(previous: [:], current: current).isEmpty)
        check("unchanged says nothing", CITransition.between(previous: current, current: current).isEmpty)
    }

    static func seen() {
        section("PRSeen.update")
        let first = PRSeen.update(saved: nil, latest: ["a": 10, "b": 0], open: ["a", "b"])
        check("the first time, all is seen", first.unseen.isEmpty && first.seen == ["a": 10, "b": 0])
        let second = PRSeen.update(saved: first.seen, latest: ["a": 20, "b": 0, "c": 5, "d": 0],
                                   open: ["a", "b", "c", "d"])
        check("newer activity, and a new pull request with some", second.unseen == ["a", "c"])
        check("not marked seen by the poll", second.seen["a"] == 10 && second.seen["c"] == 0)
        let third = PRSeen.update(saved: second.seen, latest: ["a": 20], open: ["a", "b"])
        check("still unseen at the next poll", third.unseen == ["a"])
        check("closed ones forgotten", Set(third.seen.keys) == ["a", "b"])
        check("an unread one keeps its mark", third.seen["b"] == 0)
        check("older activity (deleted comment) is not news",
              PRSeen.update(saved: ["a": 10], latest: ["a": 5], open: ["a"]).unseen.isEmpty)
    }

    static func scope() {
        section("PRScope")
        let mine = PRScope.searches(.author)
        check("organization and repository searched apart", mine.count == 2
              && mine[0].contains("MedCof-Tech") && !mine[0].contains("--repo")
              && mine[1].contains("b-coimbra/coucou") && !mine[1].contains("--owner"))
        check("authored, open", mine.allSatisfy { $0.contains("--author") && $0.contains("@me") && $0.contains("open") })
        let reviews = PRScope.searches(.reviewRequested)
        check("review requested, oldest asked for",
              reviews.allSatisfy { $0.contains("--review-requested") && $0.contains("asc") && !$0.contains("--author") })
        let ref = PRRef(repo: "a/b", number: 3)!
        check("view arguments", Array(PRScope.view(ref).prefix(5)) == ["pr", "view", "3", "-R", "a/b"])

        func summary(_ number: Int, _ time: TimeInterval) -> PRSummary {
            PRSummary(ref: PRRef(repo: "a/b", number: number)!, title: "t", author: "x",
                      createdAt: Date(timeIntervalSince1970: time), isDraft: false)
        }
        let merged = PRScope.merge([[summary(1, 30), summary(2, 10)], [summary(2, 10), summary(3, 20)]])
        check("merged without duplicates", merged.map(\.ref.number) == [1, 2, 3])
        check("oldest first", PRScope.oldestFirst(merged).map(\.ref.number) == [2, 3, 1])
    }

    // MARK: - Pills and processes

    static func pills() {
        section("DevFlowPills.seed")
        let name = "coucou-devflow-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { check("defaults", false); return }
        defer { defaults.removePersistentDomain(forName: name) }
        let first = DevFlowPills.seed(["integration_github"], defaults: defaults)
        check("switched on once", first == Set(DevFlowPills.all + ["integration_github"]))
        check("saved", defaults.data(forKey: "activeIntegrations") != nil)
        check("one turned off stays off",
              DevFlowPills.seed(["integration_github"], defaults: defaults) == ["integration_github"])
    }

    static func process() {
        section("DevProcess.run")
        let echo = DevProcess.run("/bin/echo", ["a b", "$HOME"], environment: [:], timeout: 5)
        check("arguments reach the tool as they are", echo?.succeeded == true && echo?.text == "a b $HOME\n")
        let failed = DevProcess.run("/usr/bin/false", [], environment: [:], timeout: 5)
        check("a failure is not a success", failed?.succeeded == false && failed?.timedOut == false)
        let start = Date()
        let slow = DevProcess.run("/bin/sleep", ["30"], environment: [:], timeout: 0.3)
        check("stopped at the time limit", slow?.timedOut == true && slow?.succeeded == false
              && Date().timeIntervalSince(start) < 5)
        check("a missing tool → nil",
              DevProcess.run("/nonexistent/tool", [], environment: [:], timeout: 1) == nil)
    }
}
