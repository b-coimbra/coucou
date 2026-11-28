#if !APPSTORE
import Foundation

// MARK: - Notch glance (pure logic, tested by scripts/test-glance.sh)
// What the small items beside the closed notch say, which of them are shown and in which
// order. No AppKit, no AppState: everything comes in as values.

/// The items, in the order they stand on screen: left of the notch, then right of it.
enum GlanceKind: String, CaseIterable, Sendable {
    case ci, jira, meeting, usage, grokBot, slack

    var isLeft: Bool { self == .ci || self == .jira }

    var enabledKey: String { "glance.show.\(rawValue)" }

    /// The meeting, the CI dot and Grok Bot are on until turned off; the others are off
    /// until turned on.
    var onByDefault: Bool { self == .meeting || self == .ci || self == .grokBot }
}

enum GlanceSettings {
    static let maxKey = "glance.maxItems"
    static let maxRange = 2...3
    static let defaultMax = 3

    static func enabled(_ defaults: UserDefaults) -> Set<GlanceKind> {
        Set(GlanceKind.allCases.filter { defaults.object(forKey: $0.enabledKey) as? Bool ?? $0.onByDefault })
    }

    static func isOn(_ kind: GlanceKind, defaults: UserDefaults = .standard) -> Bool {
        enabled(defaults).contains(kind)
    }

    static func clamp(_ value: Int) -> Int { min(maxRange.upperBound, max(maxRange.lowerBound, value)) }

    static func maxItems(_ defaults: UserDefaults) -> Int {
        clamp(defaults.object(forKey: maxKey) as? Int ?? defaultMax)
    }
}

/// What one item shows.
enum GlanceContent: Equatable, Sendable {
    enum GrokBot: Equatable, Sendable { case approval, question, message }

    /// `checks`: those of the newest open pull request, nil when there is none to say
    case ci(checks: PRCheckState?, reviews: Int)
    case jira(key: String, category: JiraIssue.Category)
    /// `minutes` until the start, rounded up; 0 once it has started
    case meeting(start: Date, minutes: Int)
    case usage(fraction: Double, resetsAt: Date)
    case grokBot(GrokBot)
    case slack(DockBadge)
}

/// How soon an item deserves a place. Lower comes first.
enum GlanceRank: Int, Comparable, Sendable {
    /// Waiting on you: an agent is stopped until you answer. Approvals first.
    case approval = 0
    case question = 1
    /// A meeting starting within 10 minutes, or just started
    case meetingSoon = 2
    case failingCI = 3
    /// Others wait for your review, but nothing is stopped right now
    case reviews = 4
    // The rest
    case meetingLater = 5
    case message = 6
    case ci = 7
    case slack = 8
    case jira = 9
    case usage = 10

    static func < (a: GlanceRank, b: GlanceRank) -> Bool { a.rawValue < b.rawValue }
}

struct GlanceItem: Equatable, Sendable, Identifiable {
    let content: GlanceContent
    /// The pill a click opens
    let pillId: String

    var id: GlanceKind { kind }

    var kind: GlanceKind {
        switch content {
        case .ci:      return .ci
        case .jira:    return .jira
        case .meeting: return .meeting
        case .usage:   return .usage
        case .grokBot: return .grokBot
        case .slack:   return .slack
        }
    }

    var rank: GlanceRank {
        switch content {
        case .grokBot(.approval): return .approval
        case .grokBot(.question): return .question
        case .grokBot(.message):  return .message
        case .meeting(_, let minutes):
            return minutes < Glance.meetingSoonMinutes ? .meetingSoon : .meetingLater
        case .ci(let checks, let reviews):
            if checks == .failing { return .failingCI }
            return reviews > 0 ? .reviews : .ci
        case .slack: return .slack
        case .jira:  return .jira
        case .usage: return .usage
        }
    }

    /// The meeting is amber under 5 minutes, and while it has just started.
    var isMeetingImminent: Bool {
        if case .meeting(_, let minutes) = content { return minutes < Glance.meetingAmberMinutes }
        return false
    }
}

/// Everything the items are made from. A field is empty when its source has nothing.
struct GlanceInputs: Sendable {
    /// The pills on the island: an item whose pill is off isn't shown
    var pills: Set<String> = []

    // Dev flow
    var myPRs: [PRRow] = []
    var reviewCount = 0
    var jiraKey: String?
    /// The last issue Jira answered with
    var jiraIssue: JiraIssue?

    // Day
    var meeting: MeetingEvent?

    // Agents
    var usage: UsageResetInfo?

    // Grok Bot
    var grokApprovals = 0
    var grokQuestions = 0
    var grokUnread = false

    // Dock
    var slack = DockBadge.none
}

enum Glance {
    static let meetingSoonMinutes = 10
    static let meetingAmberMinutes = 5
    /// A meeting further away than this isn't shown: its time alone wouldn't say which day
    static let meetingHorizon: TimeInterval = 12 * 3600

    static func items(_ input: GlanceInputs, now: Date) -> [GlanceItem] {
        [ci(input), jira(input), meeting(input, now: now), usage(input, now: now),
         grokBot(input), slack(input)].compactMap { $0 }
    }

    /// The items to show: those turned on, only approvals and meetings during Do not
    /// disturb, the `max` (2 or 3) that come first, returned in screen order.
    static func select(_ items: [GlanceItem], enabled: Set<GlanceKind>, max: Int,
                       doNotDisturb: Bool) -> [GlanceItem] {
        let allowed = items.filter {
            enabled.contains($0.kind) && (!doNotDisturb || $0.rank == .approval || $0.kind == .meeting)
        }
        let first = allowed
            .sorted { ($0.rank, order($0.kind)) < ($1.rank, order($1.kind)) }
            .prefix(GlanceSettings.clamp(max))
        return first.sorted { order($0.kind) < order($1.kind) }
    }

    /// The glance sits beside a physical notch only, while the island is closed.
    static func isVisible(hasNotch: Bool, inCorner: Bool, isOpen: Bool) -> Bool {
        hasNotch && !inCorner && !isOpen
    }

    private static func order(_ kind: GlanceKind) -> Int {
        GlanceKind.allCases.firstIndex(of: kind) ?? 0
    }

    // MARK: - The items

    /// The checks of the newest open pull request, and how many reviews wait. The click goes
    /// to a failing pull request first, else to the reviews that wait.
    private static func ci(_ input: GlanceInputs) -> GlanceItem? {
        let hasMine = input.pills.contains(DevFlowPills.pullRequests)
        let newest = hasMine
            ? input.myPRs.max { ($0.summary.createdAt, $0.id) < ($1.summary.createdAt, $1.id) }
            : nil
        var checks = newest?.detail?.checks
        if checks == .noChecks { checks = nil }
        let reviews = input.pills.contains(DevFlowPills.reviews) ? input.reviewCount : 0
        guard checks != nil || reviews > 0 else { return nil }
        let toReviews = reviews > 0 && checks != .failing
        return GlanceItem(content: .ci(checks: checks, reviews: reviews),
                          pillId: toReviews ? DevFlowPills.reviews : DevFlowPills.pullRequests)
    }

    private static func jira(_ input: GlanceInputs) -> GlanceItem? {
        guard input.pills.contains(DevFlowPills.jira), let key = input.jiraKey, !key.isEmpty else { return nil }
        // Another issue's status says nothing about this one.
        let category = input.jiraIssue.flatMap { $0.key == key ? $0.category : nil } ?? .unknown
        return GlanceItem(content: .jira(key: key, category: category), pillId: DevFlowPills.jira)
    }

    private static func meeting(_ input: GlanceInputs, now: Date) -> GlanceItem? {
        guard input.pills.contains(DayPills.meeting), let meeting = input.meeting, meeting.end > now else { return nil }
        let wait = meeting.start.timeIntervalSince(now)
        guard wait <= meetingHorizon, wait > -MeetingSchedule.justStarted else { return nil }
        let minutes = Swift.max(0, Int((wait / 60).rounded(.up)))
        return GlanceItem(content: .meeting(start: meeting.start, minutes: minutes), pillId: DayPills.meeting)
    }

    /// Only what Claude Code reported: an estimate has no fraction to draw.
    private static func usage(_ input: GlanceInputs, now: Date) -> GlanceItem? {
        guard input.pills.contains(AgentPills.usageReset), let info = input.usage, info.resetsAt > now,
              case .claudeCode(_, let used) = info.source else { return nil }
        return GlanceItem(content: .usage(fraction: min(1, Swift.max(0, used / 100)), resetsAt: info.resetsAt),
                          pillId: AgentPills.usageReset)
    }

    private static func grokBot(_ input: GlanceInputs) -> GlanceItem? {
        guard input.pills.contains(grokPillId) else { return nil }
        let status: GlanceContent.GrokBot
        if input.grokApprovals > 0 { status = .approval }
        else if input.grokQuestions > 0 { status = .question }
        else if input.grokUnread { status = .message }
        else { return nil }
        return GlanceItem(content: .grokBot(status), pillId: grokPillId)
    }

    static let grokPillId = "agent_grokbot"

    private static func slack(_ input: GlanceInputs) -> GlanceItem? {
        guard input.pills.contains(BadgePills.slack), input.slack.isUnread else { return nil }
        return GlanceItem(content: .slack(input.slack), pillId: BadgePills.slack)
    }
}
#endif
