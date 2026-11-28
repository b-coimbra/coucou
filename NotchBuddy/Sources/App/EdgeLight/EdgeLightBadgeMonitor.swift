#if !APPSTORE
import Foundation

// MARK: - Badge Monitor
// Polls Dock badge counts for Slack and Mail (read by DockBadgeReader, via lsappinfo).
// Ported from Minhoca's fontes.py badge monitoring.

enum EdgeLightBadgeSource {
    case slack
    case mail
    
    var bundleId: String {
        switch self {
        case .slack: return "com.tinyspeck.slackmacgap"
        case .mail: return "com.apple.mail"
        }
    }
}

final class EdgeLightBadgeMonitor: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private let callback: @Sendable (EdgeLightBadgeSource, Int) -> Void
    private var lastCounts: [EdgeLightBadgeSource: Int] = [:]

    /// `onIncrease` is called on a background queue.
    init(onIncrease: @escaping @Sendable (EdgeLightBadgeSource, Int) -> Void) {
        self.callback = onIncrease
    }
    
    func start() {
        guard timer == nil else { return }
        
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1.0, repeating: 3.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
    }
    
    func stop() {
        timer?.cancel()
        timer = nil
    }
    
    private func poll() {
        for source in [EdgeLightBadgeSource.slack, .mail] {
            if let count = readBadgeCount(bundleId: source.bundleId) {
                checkIncrease(source: source, newCount: count)
            } else {
                // App not running, forget last count
                lastCounts.removeValue(forKey: source)
            }
        }
    }
    
    private func checkIncrease(source: EdgeLightBadgeSource, newCount: Int) {
        let previous = lastCounts[source]
        lastCounts[source] = newCount
        
        // Only trigger on increase (not on first read)
        if let previous = previous, newCount > previous {
            callback(source, newCount)
        }
    }
    
    /// nil when the app isn't running or its badge couldn't be read
    private func readBadgeCount(bundleId: String) -> Int? {
        guard case .label(let label) = DockBadgeReader.read(bundleId: bundleId) else { return nil }
        return parseBadgeCount(label: label)
    }

    /// Parse badge label: "3" -> 3, "•" -> 1, "99+" -> 99, "" -> 0
    private func parseBadgeCount(label: String) -> Int {
        guard !label.isEmpty else { return 0 }
        
        // Try to extract number
        if let match = label.range(of: #"\d+"#, options: .regularExpression) {
            if let num = Int(label[match]) {
                return num
            }
        }
        
        // "•" or other non-numeric indicator = 1
        return 1
    }
}
#endif
