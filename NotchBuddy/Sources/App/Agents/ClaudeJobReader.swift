#if !APPSTORE
import Darwin
import Foundation

/// Finds the headless Claude Code jobs of this user with system calls only: no subprocess,
/// nothing written. Blocking: call it off the main thread.
enum ClaudeJobReader {
    private struct Entry {
        let pid: Int32
        let parent: Int32
        let name: String
        let startedAt: Date
    }

    /// nil when the processes couldn't be listed (nothing can be said to have finished).
    /// Processes started by Coucou itself (its chat, its helpers) are not jobs.
    static func jobs() -> [ClaudeJob]? {
        guard let entries = processes() else { return nil }
        let parents = Dictionary(entries.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })
        let own: Set<Int32> = [getpid()]
        let matches = entries.filter { entry in
            guard ClaudeJobDetector.mayBeClaude(processName: entry.name),
                  !ClaudeJobDetector.isDescendant(entry.pid, of: own, parents: parents),
                  let buffer = argumentBuffer(entry.pid),
                  let args = ClaudeJobDetector.parseProcessArguments(buffer) else { return false }
            return ClaudeJobDetector.isHeadlessClaude(executable: args.executable, argv: args.argv)
        }
        // A launcher and the process it starts are one job.
        let found = Set(matches.map(\.pid))
        let home = NSHomeDirectory()
        return matches
            .filter { !ClaudeJobDetector.isDescendant($0.pid, of: found, parents: parents) }
            .map { entry in
                let path = workingFolder(entry.pid)
                let folder = ClaudeJobDetector.folderName(path: path, home: home) {
                    FileManager.default.fileExists(atPath: $0 + "/.git")
                }
                return ClaudeJob(pid: entry.pid, startedAt: entry.startedAt, path: path, folder: folder)
            }
    }

    private static func processes() -> [Entry]? {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Room for the processes started between the two calls.
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = list.count * stride
        guard sysctl(&query, u_int(query.count), &list, &size, nil, 0) == 0 else { return nil }
        return list.prefix(size / stride).map { info in
            let start = info.kp_proc.p_un.__p_starttime
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Entry(pid: info.kp_proc.p_pid, parent: info.kp_eproc.e_ppid, name: name,
                         startedAt: Date(timeIntervalSince1970: TimeInterval(start.tv_sec)
                                            + TimeInterval(start.tv_usec) / 1_000_000))
        }
    }

    private static func argumentBuffer(_ pid: Int32) -> [UInt8]? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, u_int(query.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    private static func workingFolder(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
