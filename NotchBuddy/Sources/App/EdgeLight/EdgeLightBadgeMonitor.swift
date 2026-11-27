import Foundation

// MARK: - Badge Monitor
// Polls Dock badge counts for Slack and Mail via lsappinfo.
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
    private let callback: (EdgeLightBadgeSource, Int) -> Void
    private var lastCounts: [EdgeLightBadgeSource: Int] = [:]
    
    init(onIncrease: @escaping (EdgeLightBadgeSource, Int) -> Void) {
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
    
    /// Read badge count from app via lsappinfo
    private func readBadgeCount(bundleId: String) -> Int? {
        // Find ASN (Application Serial Number)
        guard let asn = findASN(bundleId: bundleId) else {
            return nil
        }
        
        // Read StatusLabel
        guard let label = readStatusLabel(asn: asn) else {
            return nil
        }
        
        return parseBadgeCount(label: label)
    }
    
    private func findASN(bundleId: String) -> String? {
        guard let output = runLsappinfo(["find", "bundleid=\(bundleId)"]) else { return nil }

        // Extract ASN:0x...-0x...:
        let pattern = "ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:"
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    private func readStatusLabel(asn: String) -> String? {
        guard let output = runLsappinfo(["info", "-only", "StatusLabel", asn]) else { return nil }

        // Extract "label" = "value"
        let pattern = #""label"\s*=\s*"([^"]*)""#
        if let range = output.range(of: pattern, options: .regularExpression) {
            let match = output[range]
            // Extract the value between last pair of quotes
            if let valueRange = match.range(of: #""[^"]*"$"#, options: .regularExpression) {
                return String(match[valueRange].dropFirst().dropLast())
            }
        }

        // Empty label (no badge)
        if output.contains("StatusLabel") || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }

        return nil
    }

    private func runLsappinfo(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            // readToEnd() throws a Swift error where readDataToEndOfFile() raises an
            // Objective-C exception. Read before waiting so a full pipe can't block the child.
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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
