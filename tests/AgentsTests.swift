import Foundation

// Pure logic of the agent features (usage reset countdown, headless Claude jobs, Cursor
// agent pulse), plus one look at real processes: stand-ins that are copies of this test
// binary, never Claude Code. All data is synthetic; no network. Run: scripts/test-agents.sh

@main
enum AgentsTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func section(_ name: String) { print(name) }

    static func main() {
        standIn()
        dailyTime()
        nextDaily()
        daylightSaving()
        usageReset()
        durations()
        detection()
        processArguments()
        folders()
        jobTracker()
        cursorFinished()
        cursorWaiting()
        pills()
        realProcesses()

        if failures > 0 {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
        print("\nAll tests passed.")
    }

    // MARK: - Calendar helpers

    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    /// "2026-03-08T07:00:00Z" → Date
    static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - Daily reset time

    static func dailyTime() {
        section("DailyResetTime")
        check("18:30", DailyResetTime("18:30") == DailyResetTime(hour: 18, minute: 30))
        check("7:05, with spaces", DailyResetTime(" 7:05 ") == DailyResetTime(hour: 7, minute: 5))
        check("00:00", DailyResetTime("00:00") == DailyResetTime(hour: 0, minute: 0))
        for bad in ["", "18", "24:00", "18:60", "18:3", "6:30pm", "-1:00", "18:30:00", ":30"] {
            check("\"\(bad)\" → nil", DailyResetTime(bad) == nil)
        }
        check("default is 18:30", DailyResetTime.fallback.text == "18:30")
        check("text pads", DailyResetTime(hour: 7, minute: 5).text == "07:05")
    }

    static func nextDaily() {
        section("UsageReset.nextDaily")
        let paris = calendar("Europe/Paris")
        let time = DailyResetTime.fallback
        func next(_ now: String) -> Date { UsageReset.nextDaily(time, after: utc(now), calendar: paris) }
        // Paris is UTC+1 in January.
        check("before the time: today", next("2026-01-15T09:00:00Z") == utc("2026-01-15T17:30:00Z"))
        check("after the time: tomorrow", next("2026-01-15T18:00:00Z") == utc("2026-01-16T17:30:00Z"))
        check("at the time exactly: tomorrow", next("2026-01-15T17:30:00Z") == utc("2026-01-16T17:30:00Z"))
        check("one second before: now's day", next("2026-01-15T17:29:59Z") == utc("2026-01-15T17:30:00Z"))
        check("month rollover", next("2026-01-31T20:00:00Z") == utc("2026-02-01T17:30:00Z"))
        check("year rollover", next("2026-12-31T20:00:00Z") == utc("2027-01-01T17:30:00Z"))
        check("just before local midnight", next("2026-01-15T22:59:59Z") == utc("2026-01-16T17:30:00Z"))
        check("just after local midnight", next("2026-01-15T23:00:01Z") == utc("2026-01-16T17:30:00Z"))
        let midnight = UsageReset.nextDaily(DailyResetTime(hour: 0, minute: 0),
                                            after: utc("2026-01-15T12:00:00Z"), calendar: paris)
        check("a midnight reset is the next midnight", midnight == utc("2026-01-15T23:00:00Z"))
    }

    static func daylightSaving() {
        section("Daylight saving (America/New_York)")
        let ny = calendar("America/New_York")
        func next(_ h: Int, _ m: Int, _ now: String) -> Date {
            UsageReset.nextDaily(DailyResetTime(hour: h, minute: m), after: utc(now), calendar: ny)
        }
        // 2026-03-08: 02:00 EST becomes 03:00 EDT (07:00Z).
        check("across spring forward the day is 23 h",
              next(18, 30, "2026-03-07T23:30:00Z") == utc("2026-03-08T22:30:00Z"))
        check("a skipped time is when the clock jumps",
              next(2, 30, "2026-03-08T05:00:00Z") == utc("2026-03-08T07:00:00Z"))
        check("the day after, the time exists again",
              next(2, 30, "2026-03-08T07:00:01Z") == utc("2026-03-09T06:30:00Z"))
        // 2026-11-01: 02:00 EDT becomes 01:00 EST (06:00Z); 01:30 is read twice.
        check("across fall back the day is 25 h",
              next(18, 30, "2026-10-31T22:30:00Z") == utc("2026-11-01T23:30:00Z"))
        check("a repeated time: the first reading",
              next(1, 30, "2026-11-01T04:30:00Z") == utc("2026-11-01T05:30:00Z"))
        check("between the two readings: tomorrow",
              next(1, 30, "2026-11-01T05:45:00Z") == utc("2026-11-02T06:30:00Z"))
        check("during the second reading: tomorrow",
              next(1, 30, "2026-11-01T06:15:00Z") == utc("2026-11-02T06:30:00Z"))
    }

    // MARK: - Which limit is counted down

    static func usageReset() {
        section("UsageReset.compute")
        let paris = calendar("Europe/Paris")
        let now = utc("2026-01-15T09:00:00Z")
        func window(_ pct: Double, _ hours: Double) -> PlanWindow {
            PlanWindow(usedPct: pct, resetsAt: now.addingTimeInterval(hours * 3600))
        }
        func compute(_ five: PlanWindow?, _ week: PlanWindow?) -> UsageResetInfo {
            UsageReset.compute(usage: PlanUsage(fiveHour: five, sevenDay: week, updatedAt: now),
                               daily: .fallback, now: now, calendar: paris)
        }
        let none = UsageReset.compute(usage: nil, daily: .fallback, now: now, calendar: paris)
        check("no data: estimate at 18:30 local", none.isEstimate && none.resetsAt == utc("2026-01-15T17:30:00Z"))
        let live = compute(window(43, 2), window(12, 90))
        check("the running 5-hour window", live.source == .claudeCode(.fiveHour, usedPct: 43)
              && live.resetsAt == now.addingTimeInterval(7200) && !live.isEstimate)
        let full = compute(window(10, 2), window(100, 90))
        check("a used-up week wins", full.source == .claudeCode(.week, usedPct: 100))
        let weekOnly = compute(window(80, -1), window(12, 90))
        check("5-hour window past: the week", weekOnly.source == .claudeCode(.week, usedPct: 12))
        check("5-hour only", compute(window(5, 1), nil).source == .claudeCode(.fiveHour, usedPct: 5))
        check("all past: estimate", compute(window(80, -1), window(100, -1)).isEstimate)
        check("a reset time equal to now is past", compute(window(80, 0), nil).isEstimate)
        check("empty usage: estimate", compute(nil, nil).isEstimate)
    }

    static func durations() {
        section("DurationParts")
        check("59 s elapsed", DurationParts.of(59) == .underMinute)
        check("1 s left rounds up", DurationParts.of(1, roundUp: true) == .minutes(1))
        check("0 s left", DurationParts.of(0, roundUp: true) == .underMinute)
        check("negative", DurationParts.of(-90) == .underMinute)
        check("12 min", DurationParts.of(12 * 60 + 40) == .minutes(12))
        check("3599 s left is 1 h", DurationParts.of(3599, roundUp: true) == .hours(1, minutes: 0))
        check("2 h 14", DurationParts.of(2 * 3600 + 14 * 60) == .hours(2, minutes: 14))
        check("3 d 4 h", DurationParts.of(3 * 86400 + 4 * 3600 + 59) == .days(3, hours: 4))
    }

    // MARK: - Which processes are headless jobs

    static func detection() {
        section("ClaudeJobDetector.isHeadlessClaude")
        let native = "/Users/someone/.local/share/claude/versions/2.1.332"
        func headless(_ argv: [String], _ executable: String = native) -> Bool {
            ClaudeJobDetector.isHeadlessClaude(executable: executable, argv: argv)
        }
        check("claude -p", headless(["claude", "-p", "do something"]))
        check("claude --print", headless(["claude", "--print", "x"]))
        check("flag after other options", headless(["claude", "--model", "opus", "-p"]))
        check("-cp (continue + print)", headless(["claude", "-cp", "x"]))
        check("full path as argv[0]", headless(["/opt/homebrew/bin/claude", "-p"], "/opt/homebrew/bin/claude"))
        check("npm native binary", headless(["claude", "-p"], "/x/@anthropic-ai/claude-code/bin/claude.exe"))
        check("node running the npm script", headless(
            ["node", "--no-warnings", "/opt/homebrew/bin/claude", "-p"], "/opt/homebrew/bin/node"))
        check("node running cli.js", headless(
            ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js", "--print"], "/usr/local/bin/node"))
        check("interactive session", !headless(["claude"]))
        check("interactive with a prompt", !headless(["claude", "fix the bug"]))
        check("resume, no print", !headless(["claude", "--resume", "abc"]))
        check("\"-p\" inside the prompt only", !headless(["claude", "explain the -p flag"]))
        check("after --", !headless(["claude", "--", "-p"]))
        check("editor session fed with stream-json", !headless(
            ["claude", "-p", "--output-format", "stream-json", "--input-format", "stream-json"]))
        check("--input-format=stream-json", !headless(["claude", "--print", "--input-format=stream-json"]))
        check("stream-json output alone is a job", headless(["claude", "-p", "--output-format", "stream-json"]))
        check("claude mcp …", !headless(["claude", "mcp", "add", "x", "-p"]))
        check("claude update", !headless(["claude", "update", "-p"]))
        check("another program with -p", !headless(["mkdir", "-p", "claude"], "/bin/mkdir"))
        check("node running another script", !headless(["node", "server.js", "-p"], "/usr/local/bin/node"))
        check("Coucou's hook relay", !headless(
            ["python3", "/Users/someone/Library/Application Support/NotchBuddy/nb-hook.py", "-p"], "/usr/bin/python3"))
        check("the desktop app", !headless(
            ["/Applications/Claude.app/Contents/MacOS/Claude", "-p"], "/Applications/Claude.app/Contents/MacOS/Claude"))
        check("no arguments", !headless([]))

        section("ClaudeJobDetector.mayBeClaude")
        for name in ["claude", "claude.exe", "node", "bun", "2.1.332"] {
            check(name, ClaudeJobDetector.mayBeClaude(processName: name))
        }
        for name in ["zsh", "Claude", "python3", "2", "", "git"] {
            check("not \"\(name)\"", !ClaudeJobDetector.mayBeClaude(processName: name))
        }

        section("ClaudeJobDetector.isDescendant")
        let parents: [Int32: Int32] = [10: 1, 20: 10, 30: 20, 40: 50, 50: 40]
        check("child", ClaudeJobDetector.isDescendant(20, of: [10], parents: parents))
        check("grandchild", ClaudeJobDetector.isDescendant(30, of: [10], parents: parents))
        check("not itself", !ClaudeJobDetector.isDescendant(10, of: [10], parents: parents))
        check("not a parent", !ClaudeJobDetector.isDescendant(10, of: [30], parents: parents))
        check("a loop ends", !ClaudeJobDetector.isDescendant(40, of: [10], parents: parents))
    }

    static func processArguments() {
        section("ClaudeJobDetector.parseProcessArguments")
        func buffer(_ argc: UInt32, _ executable: String, _ strings: [String], padding: Int = 3) -> [UInt8] {
            var bytes = (0..<4).map { UInt8((argc >> (8 * $0)) & 0xFF) }
            bytes += Array(executable.utf8) + [0] + [UInt8](repeating: 0, count: padding)
            for s in strings { bytes += Array(s.utf8) + [0] }
            return bytes
        }
        let parsed = ClaudeJobDetector.parseProcessArguments(
            buffer(3, "/bin/claude", ["claude", "-p", "héllo", "SECRET=1", "HOME=/x"]))
        check("executable", parsed?.executable == "/bin/claude")
        check("arguments up to the count, no environment", parsed?.argv == ["claude", "-p", "héllo"])
        check("an empty argument is kept", ClaudeJobDetector.parseProcessArguments(
            buffer(3, "/c", ["claude", "", "-p"]))?.argv == ["claude", "", "-p"])
        check("no padding", ClaudeJobDetector.parseProcessArguments(
            buffer(1, "/c", ["claude"], padding: 0))?.argv == ["claude"])
        check("truncated → nil", ClaudeJobDetector.parseProcessArguments(buffer(4, "/c", ["claude"])) == nil)
        check("no count → nil", ClaudeJobDetector.parseProcessArguments(buffer(0, "/c", [])) == nil)
        check("absurd count → nil", ClaudeJobDetector.parseProcessArguments(buffer(.max, "/c", ["a"])) == nil)
        check("empty → nil", ClaudeJobDetector.parseProcessArguments([]) == nil)
    }

    static func folders() {
        section("ClaudeJobDetector.folderName")
        let home = "/Users/someone"
        var looked: [String] = []
        func name(_ path: String, roots: Set<String> = []) -> String {
            looked = []
            return ClaudeJobDetector.folderName(path: path, home: home) {
                looked.append($0)
                return roots.contains($0)
            }
        }
        check("the repository above", name("\(home)/dev/app/src/ui", roots: ["\(home)/dev/app"]) == "app")
        check("no repository: the folder", name("\(home)/dev/scratch") == "scratch")
        check("never looks at home", !looked.contains(home))
        check("home", name(home) == "~")
        check("root", name("/") == "/")
        check("unreadable", name("") == "")
        check("outside home", name("/tmp/work") == "work")
        check("a protected folder is not looked into",
              name("\(home)/Documents/repo/src", roots: ["\(home)/Documents/repo"]) == "src" && looked.isEmpty)
        check("nor an external volume", name("/Volumes/Disk/repo") == "repo" && looked.isEmpty)
    }

    // MARK: - Start and finish

    static func jobTracker() {
        section("ClaudeJobTracker")
        let t0 = utc("2026-01-15T09:00:00Z")
        func job(_ pid: Int32, _ start: Double, _ folder: String) -> ClaudeJob {
            ClaudeJob(pid: pid, startedAt: t0.addingTimeInterval(start), path: "/w/\(folder)", folder: folder)
        }
        var tracker = ClaudeJobTracker()
        check("nothing at first", tracker.update([], now: t0).isEmpty)
        check("a start is not a finish", tracker.update([job(1, 0, "app")], now: t0).isEmpty)
        check("still running", tracker.update([job(1, 0, "other")], now: t0.addingTimeInterval(10)).isEmpty)
        check("keeps its first folder", tracker.jobs.map(\.folder) == ["app"])
        let done = tracker.update([], now: t0.addingTimeInterval(12 * 60))
        check("gone: finished once", done.count == 1 && done[0].folder == "app" && done[0].duration == 720)
        check("not announced again", tracker.update([], now: t0.addingTimeInterval(730)).isEmpty)

        _ = tracker.update([job(7, 0, "a")], now: t0)
        let reused = tracker.update([job(7, 100, "b")], now: t0.addingTimeInterval(110))
        check("a reused pid is another run", reused.map(\.folder) == ["a"] && tracker.jobs.map(\.folder) == ["b"])

        _ = tracker.update([job(7, 100, "b"), job(8, 200, "c"), job(9, 50, "d")], now: t0.addingTimeInterval(210))
        check("running jobs oldest first", tracker.jobs.map(\.folder) == ["d", "b", "c"])
        let two = tracker.update([job(8, 200, "c")], now: t0.addingTimeInterval(300))
        check("several at once, longest first", two.map(\.folder) == ["d", "b"])
    }

    // MARK: - Cursor

    static func cursorFinished() {
        section("CursorPingDetector: finished")
        let t = utc("2026-01-15T09:00:00Z")
        var d = CursorPingDetector()
        check("Stop completed", d.event("Stop", session: "a", status: "completed", generation: "g1", now: t) == .finished)
        check("same generation again", d.event("Stop", session: "a", status: "completed", generation: "g1",
                                               now: t.addingTimeInterval(60)) == nil)
        check("next generation", d.event("Stop", session: "a", status: "completed", generation: "g2", now: t) == .finished)
        check("another session", d.event("Stop", session: "b", status: "completed", generation: "g2", now: t) == .finished)
        check("aborted by the user: nothing", d.event("Stop", session: "a", status: "aborted", generation: "g3") == nil)
        check("error", d.event("Stop", session: "a", status: "error", generation: "g4") == .failed)
        check("no status (Claude Code in Cursor)", d.event("Stop", session: "c", now: t) == .finished)
        check("without generation, an echo", d.event("Stop", session: "c", now: t.addingTimeInterval(1)) == nil)
        check("without generation, later", d.event("Stop", session: "c", now: t.addingTimeInterval(30)) == .finished)
        _ = d.event("SessionEnd", session: "c")
        check("forgotten at session end", d.event("Stop", session: "c", now: t.addingTimeInterval(30.5)) == .finished)
        for name in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop", "StopFailure"] {
            check("\(name) says nothing", d.event(name, session: "a", tool: "Shell") == nil)
        }
        check("blue when done", CursorPing.finished.colorHex == "#3B9EFF")
        check("amber otherwise", CursorPing.needsInput.colorHex == "#F5A524" && CursorPing.failed.colorHex == "#F5A524")
    }

    static func cursorWaiting() {
        section("CursorPingDetector: needs input")
        var d = CursorPingDetector()
        func ask(_ s: String = "a") -> CursorPing? { d.event("PreToolUse", session: s, tool: "AskQuestion") }
        check("AskQuestion", ask() == .needsInput && d.isWaiting("a"))
        check("repeated: once", ask() == nil)
        check("answered", d.event("PostToolUse", session: "a", tool: "AskQuestion") == nil && !d.isWaiting("a"))
        check("asks again", ask() == .needsInput)
        check("work resumes", d.event("PreToolUse", session: "a", tool: "Shell") == nil && !d.isWaiting("a"))
        _ = ask()
        check("another session's work changes nothing",
              d.event("PostToolUse", session: "b") == nil && d.isWaiting("a"))
        check("Stop ends the wait", d.event("Stop", session: "a", status: "completed") == .finished && !d.isWaiting("a"))
        check("a notification ending in ?", d.event("Notification", session: "a", message: "Continue?") == .needsInput)
        _ = d.event("UserPromptSubmit", session: "a")
        check("another notification", d.event("Notification", session: "a", message: "Done.") == nil && !d.isWaiting("a"))
        check("a card shown", d.requestShown(session: "a") == .needsInput && d.isWaiting("a"))
        check("a second card is news too", d.requestShown(session: "a") == .needsInput)
        check("the question's twin hook doesn't end the wait",
              d.event("PreToolUse", session: "a", tool: "AskUserQuestion") == nil && d.isWaiting("a"))
        _ = d.event("SessionEnd", session: "a")
        check("session end", !d.isWaiting("a"))
    }

    // MARK: - Pills

    static func pills() {
        section("AgentPills.seed")
        let suite = "coucou-agents-tests-\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AgentPills.seed(["integration_github"], defaults: defaults)
        check("switched on once", first == Set(["integration_github"] + AgentPills.all))
        check("one turned off stays off", AgentPills.seed(["integration_github"], defaults: defaults) == ["integration_github"])
        check("the ids are stable", AgentPills.all == ["integration_usage_reset", "integration_claude_jobs"])
    }

    // MARK: - Real processes (stand-ins)

    private static let standInLife: UInt32 = 20

    /// This binary, copied under a Claude-like path, only waits. With `--detach` it starts
    /// such a copy and leaves, so the copy no longer descends from the tests.
    static func standIn() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--detach" {
            let child = launch(arguments[2], ["-p", "synthetic prompt"], folder: nil)
            print(child?.processIdentifier ?? 0)
            exit(0)
        }
        if arguments[0].contains("/claude/versions/") {
            sleep(standInLife)
            exit(0)
        }
    }

    private static func launch(_ executable: String, _ arguments: [String], folder: URL?,
                               output: Pipe? = nil) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        process.standardOutput = output.map { $0 as Any } ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        return process
    }

    static func realProcesses() {
        section("ClaudeJobReader (stand-in processes)")
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("coucou-agents-\(getpid())")
        defer { try? files.removeItem(at: root) }
        let versions = root.appendingPathComponent("claude/versions")
        let repo = root.appendingPathComponent("stand-in-repo")
        let work = repo.appendingPathComponent("src")
        let binary = versions.appendingPathComponent("9.9.9").path
        do {
            try files.createDirectory(at: versions, withIntermediateDirectories: true)
            try files.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try files.createDirectory(at: work, withIntermediateDirectories: true)
            try files.copyItem(atPath: Bundle.main.executablePath ?? CommandLine.arguments[0], toPath: binary)
        } catch {
            check("stand-in set up", false)
            return
        }

        guard let child = launch(binary, ["-p"], folder: work) else { return check("child started", false) }
        defer { child.terminate() }
        usleep(500_000)
        let mine = ClaudeJobReader.jobs()
        check("the processes are listed", mine != nil)
        check("a process Coucou started is not a job", mine?.contains { $0.pid == child.processIdentifier } == false)

        let output = Pipe()
        guard let launcher = launch(Bundle.main.executablePath ?? CommandLine.arguments[0],
                                    ["--detach", binary], folder: work, output: output)
        else { return check("launcher started", false) }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        launcher.waitUntilExit()
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
        else { return check("detached stand-in started", false) }
        defer { kill(pid, SIGTERM) }
        usleep(500_000)
        let job = ClaudeJobReader.jobs()?.first { $0.pid == pid }
        check("a detached headless run is found", job != nil)
        check("with its repository's name", job?.folder == "stand-in-repo")
        check("its working folder", job?.path.hasSuffix("/stand-in-repo/src") == true)
        check("and its start time", job.map { abs($0.startedAt.timeIntervalSinceNow) < 30 } == true)
    }
}
