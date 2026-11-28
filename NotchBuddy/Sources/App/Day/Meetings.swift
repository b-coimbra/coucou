#if !APPSTORE
import Foundation

// MARK: - The next meeting (pure logic)
// What of a calendar event is kept, which meeting is shown, which link may be opened and when
// the light pulses. No EventKit, no AppKit. Event content lives in memory only.

/// The part of a calendar event Coucou keeps. Its notes are never read.
struct MeetingEvent: Sendable, Equatable {
    let id: String
    /// One line, without control characters
    let title: String
    let start: Date
    let end: Date
    var isAllDay = false
    var isDeclined = false
    var isCanceled = false
    /// Already validated by MeetingLink
    var joinURL: URL? = nil
}

// MARK: - Meeting links

enum MeetingLink {
    /// A host must be one of these, or end with "." and one of these.
    static let allowedHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com"]

    /// The URL if `text` is, as a whole, an https address on an allowed meeting host, else nil.
    static func validated(_ text: String) -> URL? {
        // Printable ASCII only: no spaces, controls, look-alike letters or backslashes, which
        // parsers disagree about.
        guard !text.isEmpty, text.count <= 2048,
              text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) && $0 != "\\" }),
              let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              // A percent-encoded or internationalised host is not taken apart: refused.
              parts.percentEncodedHost?.lowercased() == host,
              isAllowed(host: host),
              let url = parts.url,
              // What is opened must name the same host as what was checked.
              url.host()?.lowercased() == host
        else { return nil }
        return url
    }

    private static func isAllowed(host: String) -> Bool {
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789-."
        guard host.allSatisfy({ letters.contains($0) }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The meeting link of an event, from its structured fields only: its URL, else an address
    /// written in its location or structured location.
    static func find(url: URL?, location: String?, structuredLocation: String?) -> URL? {
        if let url, let found = validated(url.absoluteString) { return found }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'()[]{},;|"))
        for field in [location, structuredLocation] {
            for word in (field ?? "").components(separatedBy: separators) {
                // A full stop ending a sentence is not part of the address.
                var word = Substring(word)
                while word.hasSuffix(".") { word = word.dropLast() }
                if let found = validated(String(word)) { return found }
            }
        }
        return nil
    }
}

// MARK: - Which meeting

enum MeetingSchedule {
    /// A meeting starting this soon comes before one that has just started.
    static let soon: TimeInterval = 5 * 60
    /// A meeting that started this recently stays shown (there is still time to join).
    static let justStarted: TimeInterval = 10 * 60
    /// Focus: how long after its start a meeting still counts as urgent.
    static let urgentAfterStart: TimeInterval = 2 * 60

    /// Timed meetings that are neither declined, canceled nor over.
    static func eligible(_ events: [MeetingEvent], now: Date) -> [MeetingEvent] {
        events.filter { !$0.isAllDay && !$0.isDeclined && !$0.isCanceled && $0.end > now }
    }

    /// The meeting to show: one starting within 5 minutes; else one that started less than
    /// 10 minutes ago; else the next to start; else the running one that ends first.
    static func next(_ events: [MeetingEvent], now: Date) -> MeetingEvent? {
        let open = eligible(events, now: now)
        let upcoming = open.filter { $0.start > now }.min(by: startsBefore)
        if let upcoming, upcoming.start.timeIntervalSince(now) <= soon { return upcoming }
        let fresh = open.filter { $0.start <= now && now.timeIntervalSince($0.start) < justStarted }
            .min { a, b in a.start != b.start ? a.start > b.start : startsBefore(a, b) }
        if let fresh { return fresh }
        if let upcoming { return upcoming }
        return open.min { a, b in a.end != b.end ? a.end < b.end : startsBefore(a, b) }
    }

    /// Earlier first; at the same time, the one with a link, then the shorter one.
    private static func startsBefore(_ a: MeetingEvent, _ b: MeetingEvent) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if (a.joinURL == nil) != (b.joinURL == nil) { return a.joinURL != nil }
        if a.end != b.end { return a.end < b.end }
        return a.id < b.id
    }

    /// true while a meeting starts within 5 minutes, or has only just started.
    static func isUrgent(_ events: [MeetingEvent], now: Date) -> Bool {
        eligible(events, now: now).contains {
            let wait = $0.start.timeIntervalSince(now)
            return wait <= soon && wait >= -urgentAfterStart
        }
    }
}

// MARK: - The 2-minute pulse

/// Which meetings have had their pulse. Remembers ids and start times, in memory only.
struct MeetingPulse: Sendable {
    static let lead: TimeInterval = 2 * 60

    private struct Key: Hashable, Sendable {
        let id: String
        let start: Date
    }

    private var done: Set<Key> = []

    /// The meetings that have just come within 2 minutes of their start, each returned once.
    /// A meeting moved to another time gets a pulse of its own.
    mutating func due(_ events: [MeetingEvent], now: Date) -> [MeetingEvent] {
        done = done.filter { $0.start > now.addingTimeInterval(-24 * 3600) }
        return MeetingSchedule.eligible(events, now: now).filter {
            let wait = $0.start.timeIntervalSince(now)
            guard wait > 0, wait <= Self.lead else { return false }
            return done.insert(Key(id: $0.id, start: $0.start)).inserted
        }
    }
}
#endif
