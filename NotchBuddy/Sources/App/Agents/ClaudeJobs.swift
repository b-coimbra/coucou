#if !APPSTORE
import Foundation

// MARK: - Headless Claude Code jobs (pure logic)
// A job is a `claude -p` / `claude --print` run. Its arguments are read only to tell that,
// then dropped: no prompt, no option and no environment variable is ever kept or logged.

struct ClaudeJob: Equatable, Sendable, Identifiable {
    let pid: Int32
    let startedAt: Date
    /// The process's working folder, "" when it couldn't be read
    let path: String
    /// The repository's (or folder's) name, "" when unknown
    let folder: String

    /// A pid is reused; with the start time it names one run.
    var id: String { "\(pid)-\(Int(startedAt.timeIntervalSince1970))" }
}

struct FinishedClaudeJob: Equatable, Sendable, Identifiable {
    let id: String
    let folder: String
    let path: String
    let duration: TimeInterval
    let finishedAt: Date
}

/// Which jobs ran at the last look and are gone now.
struct ClaudeJobTracker: Sendable {
    private var running: [String: ClaudeJob] = [:]

    /// Records what runs now; returns what disappeared since the last call, longest first.
    /// A job keeps the folder it was first seen in.
    mutating func update(_ jobs: [ClaudeJob], now: Date) -> [FinishedClaudeJob] {
        var next: [String: ClaudeJob] = [:]
        for job in jobs {
            let known = running[job.id]
            next[job.id] = (known?.folder.isEmpty == false) ? known : job
        }
        let finished = running.values
            .filter { next[$0.id] == nil }
            .map { job in
                FinishedClaudeJob(id: job.id, folder: job.folder, path: job.path,
                                  duration: max(0, now.timeIntervalSince(job.startedAt)), finishedAt: now)
            }
            .sorted { ($0.duration, $0.id) > ($1.duration, $1.id) }
        running = next
        return finished
    }

    /// The running jobs, oldest first.
    var jobs: [ClaudeJob] {
        running.values.sorted { ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid) }
    }
}

enum ClaudeJobDetector {
    /// First words after `claude` that name a command, not a prompt run.
    private static let subcommands: Set<String> = [
        "mcp", "plugin", "plugins", "doctor", "update", "upgrade", "install", "config",
        "auth", "setup-token", "agents", "migrate-installer",
    ]
    private static let runtimes: Set<String> = ["node", "bun"]
    /// The npm package ships its native binary as "claude.exe", on the Mac too.
    private static let programs: Set<String> = ["claude", "claude.exe"]

    private static func lastPart(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Worth reading the arguments of: the process names Claude Code runs under — `claude`,
    /// a JavaScript runtime, or the native install's version number ("2.1.119").
    static func mayBeClaude(processName: String) -> Bool {
        if programs.contains(processName) || runtimes.contains(processName) { return true }
        return processName.first?.isNumber == true && processName.contains(".")
            && processName.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The arguments given to Claude Code, nil when the process isn't Claude Code.
    private static func claudeArguments(executable: String, argv: [String]) -> ArraySlice<String>? {
        guard let first = argv.first else { return nil }
        let program = lastPart(first)
        let binary = lastPart(executable)
        if runtimes.contains(binary) || runtimes.contains(program) {
            // The npm install: the script comes after the runtime's own options.
            guard let i = argv.dropFirst().firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
            let script = argv[i]
            guard programs.contains(lastPart(script))
                    || script.contains("/@anthropic-ai/claude-code/") else { return nil }
            return argv[(i + 1)...]
        }
        guard programs.contains(program) || programs.contains(binary)
                || executable.contains("/claude/versions/") else { return nil }
        return argv.dropFirst()
    }

    /// A headless run: `-p` / `--print`. A run fed with `--input-format stream-json` is not
    /// one: that is how editors and the desktop app hold an interactive session.
    static func isHeadlessClaude(executable: String, argv: [String]) -> Bool {
        guard let arguments = claudeArguments(executable: executable, argv: argv) else { return false }
        if let first = arguments.first, subcommands.contains(first) { return false }
        var print = false
        var previous = ""
        for argument in arguments {
            if argument == "--" { break }
            if argument == "--input-format=stream-json"
                || (previous == "--input-format" && argument == "stream-json") { return false }
            if argument == "-p" || argument == "--print" || isShortCluster(argument) { print = true }
            previous = argument
        }
        return print
    }

    /// "-cp", "-pc": `p` among other one-letter switches.
    private static func isShortCluster(_ argument: String) -> Bool {
        guard argument.count > 2, argument.count <= 4, argument.hasPrefix("-") else { return false }
        let letters = argument.dropFirst()
        return letters.contains("p") && letters.allSatisfy { "cpdv".contains($0) }
    }

    /// The executable and the arguments in a `KERN_PROCARGS2` buffer: the argument count,
    /// the executable's path, padding, then the arguments. Reading stops at that count, so
    /// the environment that follows them is never decoded.
    static func parseProcessArguments(_ buffer: [UInt8]) -> (executable: String, argv: [String])? {
        guard buffer.count > 4 else { return nil }
        var count: UInt32 = 0
        for i in 0..<4 { count |= UInt32(buffer[i]) << (8 * i) }
        guard count > 0, count <= 4096 else { return nil }
        var position = 4
        func nextString() -> String? {
            guard position < buffer.count, let end = buffer[position...].firstIndex(of: 0) else { return nil }
            let text = String(decoding: buffer[position..<end], as: UTF8.self)
            position = end + 1
            return text
        }
        guard let executable = nextString() else { return nil }
        while position < buffer.count, buffer[position] == 0 { position += 1 }
        var argv: [String] = []
        for _ in 0..<count {
            guard let argument = nextString() else { return nil }
            argv.append(argument)
        }
        return (executable, argv)
    }

    /// Whether `pid` was started, directly or not, by one of `ancestors`.
    static func isDescendant(_ pid: Int32, of ancestors: Set<Int32>, parents: [Int32: Int32]) -> Bool {
        var current = pid
        var visited: Set<Int32> = [pid]
        while let parent = parents[current], parent > 1, visited.insert(parent).inserted {
            if ancestors.contains(parent) { return true }
            current = parent
        }
        return false
    }

    /// Folders macOS asks permission for: not looked into, their name is enough.
    private static let protectedFolders = ["Desktop", "Documents", "Downloads"]

    /// The name of the repository `path` is in, else of the folder itself.
    static func folderName(path: String, home: String, isRepositoryRoot: (String) -> Bool) -> String {
        guard !path.isEmpty else { return "" }
        if path == home { return "~" }
        let guarded = path.hasPrefix("/Volumes/")
            || protectedFolders.contains { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }
        if !guarded {
            var current = path
            for _ in 0..<12 where current != "/" && current != home && !current.isEmpty {
                if isRepositoryRoot(current) { return lastPart(current) }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return path == "/" ? "/" : lastPart(path)
    }
}
#endif
