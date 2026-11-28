#if !APPSTORE
import Foundation

// MARK: - Reading a Dock badge
// `lsappinfo` asks Launch Services for the label on a running app's Dock icon: no permission
// is needed and nothing else about the app is read. Shared by the badge pills and Edge Light.

enum DockBadgeReader {
    private static let tool = "/usr/bin/lsappinfo"
    /// Per call: one that doesn't answer is ended.
    private static let timeout: TimeInterval = 2

    /// Blocking: call it off the main thread.
    static func read(bundleId: String) -> DockBadgeReading {
        guard let found = run(["find", "bundleid=\(bundleId)"]) else { return .unavailable }
        guard let asn = LSAppInfo.asn(in: found) else { return .notRunning }
        guard let info = run(["info", "-only", "StatusLabel", asn]),
              let label = LSAppInfo.statusLabel(in: info) else { return .unavailable }
        return .label(label)
    }

    private static func run(_ arguments: [String]) -> String? {
        guard let result = DevProcess.run(tool, arguments, environment: ProcessInfo.processInfo.environment,
                                          timeout: timeout), !result.timedOut else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }
}
#endif
