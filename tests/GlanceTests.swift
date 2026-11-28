import Foundation

// Pure logic of the notch glance (which items, in which order, the cap, Do not disturb, the
// defaults), of lsappinfo's answers and of the Dock badge labels. All data is synthetic; no
// Dock, no lsappinfo, no network. Run: scripts/test-glance.sh

@main
enum GlanceTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func section(_ name: String) { print(name) }

    static func main() {
        badgeLabels()
        lsappinfoAnswers()
        badgePills()
        defaults()
        emptyItems()
        ciItem()
        meetingItem()
        otherItems()
        priorities()
        cap()
        doNotDisturb()
        visibility()

        if failures > 0 {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
        print("\nAll tests passed.")
    }

    static let now = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
    static let allPills: Set<String> = [
        "integration_prs", "integration_reviews", "integration_jira", "integration_meeting",
        "integration_usage_reset", "agent_grokbot", "integration_slack_badge",
    ]
    static let allKinds = Set(GlanceKind.allCases)

    // MARK: - Synthetic data

    static func pr(_ number: Int, _ checks: PRCheckState?, ageHours: Double) -> PRRow {
        let summary = PRSummary(ref: PRRef(repo: "example/repo", number: number)!, title: "Synthetic",
                                author: "someone", createdAt: now.addingTimeInterval(-ageHours * 3600),
                                isDraft: false)
        return PRRow(summary: summary,
                     detail: checks.map { PRDetail(checks: $0, activityCount: 0, latestActivity: nil) })
    }

    /// A meeting starting `start` minutes from `now` and lasting `length` minutes.
    static func meeting(_ start: Double, _ length: Double = 30) -> MeetingEvent {
        let from = now.addingTimeInterval(start * 60)
        return MeetingEvent(id: "m", title: "Synthetic", start: from, end: from.addingTimeInterval(length * 60))
    }

    static func reported(_ used: Double, minutes: Double = 130) -> UsageResetInfo {
        UsageResetInfo(resetsAt: now.addingTimeInterval(minutes * 60), source: .claudeCode(.fiveHour, usedPct: used))
    }

    /// Something to show for every kind: nothing urgent.
    static func quiet() -> GlanceInputs {
        var input = GlanceInputs()
        input.pills = allPills
        input.myPRs = [pr(1, .passing, ageHours: 1)]
        input.jiraKey = "POC-12"
        input.meeting = meeting(60)
        input.usage = reported(40)
        input.grokUnread = true
        input.slack = .count(3)
        return input
    }

    static func shown(_ input: GlanceInputs, enabled: Set<GlanceKind> = allKinds, max: Int = 3,
                      dnd: Bool = false) -> [GlanceKind] {
        Glance.select(Glance.items(input, now: now), enabled: enabled, max: max, doNotDisturb: dnd).map(\.kind)
    }

    static func item(_ kind: GlanceKind, _ input: GlanceInputs) -> GlanceItem? {
        Glance.items(input, now: now).first { $0.kind == kind }
    }

    // MARK: - Dock badges

    static func badgeLabels() {
        section("Dock badge labels")
        check("no label is no badge", DockBadge.parse(nil) == .none)
        check("an empty label is no badge", DockBadge.parse("") == .none)
        check("blanks are no badge", DockBadge.parse("  \n") == .none)
        check("zero is no badge", DockBadge.parse("0") == .none)
        check("a number", DockBadge.parse("3") == .count(3))
        check("a number with blanks", DockBadge.parse(" 12 ") == .count(12))
        check("99+", DockBadge.parse("99+") == .count(99, more: true))
        check("a comma between thousands", DockBadge.parse("1,234") == .count(1234))
        check("a full stop between thousands", DockBadge.parse("1.234") == .count(1234))
        check("a narrow space between thousands", DockBadge.parse("1\u{202F}234") == .count(1234))
        check("Arabic-Indic digits", DockBadge.parse("\u{0661}\u{0662}") == .count(12))
        check("a right-to-left mark", DockBadge.parse("\u{200F}5") == .count(5))
        check("a huge number is cut", DockBadge.parse("99999999999999999999") == .count(DockBadge.maxCount))
        check("a bullet is unread without a count", DockBadge.parse("•") == .unread)
        check("a black circle too", DockBadge.parse("●") == .unread)
        check("an exclamation mark too", DockBadge.parse("!") == .unread)
        check("words are never read as a count", DockBadge.parse("2 new from Sam") == .unread)
        check("separators alone are unread", DockBadge.parse("...") == .unread)
        check("a plus alone is unread", DockBadge.parse("+") == .unread)
        check("the text of a count", DockBadge.count(7).text == "7")
        check("the text of 99+", DockBadge.count(99, more: true).text == "99+")
        check("the text of a bullet", DockBadge.unread.text == "•")
        check("no text without a badge", DockBadge.none.text == nil)
    }

    static func lsappinfoAnswers() {
        section("lsappinfo answers")
        func badge(_ output: String) -> DockBadge? {
            LSAppInfo.statusLabel(in: output).map { DockBadge.parse($0) }
        }
        check("the serial number of a running app",
              LSAppInfo.asn(in: "ASN:0x0-0x1a01a:\n") == "ASN:0x0-0x1a01a:")
        check("no serial number when it isn't running", LSAppInfo.asn(in: "") == nil)
        check("a count", badge("\"StatusLabel\"={ \"label\"=\"3\" }\n") == .count(3))
        check("spaces around the equals sign",
              badge("\"StatusLabel\"={ \"label\" = \"99+\" }") == .count(99, more: true))
        check("a bullet", badge("\"StatusLabel\"={ \"label\"=\"•\" }") == .unread)
        check("an empty label", badge("\"StatusLabel\"={ \"label\"=\"\" }") == .some(DockBadge.none))
        check("a null status label", badge("\"StatusLabel\"=[ NULL ] \n") == .some(DockBadge.none))
        check("an empty answer", badge("") == .some(DockBadge.none))
        check("another answer isn't read", LSAppInfo.statusLabel(in: "error") == nil)
        check("a read label becomes a badge", DockBadgeReading.label("7").badge == .count(7))
        check("an app that isn't running has none",
              DockBadgeReading.notRunning.badge == .some(DockBadge.none))
        check("a failed read says nothing", DockBadgeReading.unavailable.badge == nil)
    }

    static func badgePills() {
        section("Badge pills")
        check("the ids are stable", BadgePills.all == ["integration_slack_badge", "integration_mail_badge"])
        check("only Slack and Mail are read",
              BadgeApp.allCases.map(\.bundleId) == ["com.tinyspeck.slackmacgap", "com.apple.mail"])
        check("each app has its pill", BadgeApp.allCases.allSatisfy { BadgeApp(pillId: $0.pillId) == $0 })
        check("another pill has no app", BadgeApp(pillId: "integration_mail") == nil)

        let suite = "coucou-glance-tests-\(ProcessInfo.processInfo.processIdentifier)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        defer { store.removePersistentDomain(forName: suite) }
        let first = BadgePills.seed(["integration_n8n"], defaults: store)
        check("on at first", first == Set(["integration_n8n"] + BadgePills.all))
        let off: Set<String> = ["integration_n8n"]
        check("one turned off stays off", BadgePills.seed(off, defaults: store) == off)
    }

    // MARK: - Settings

    static func defaults() {
        section("Settings")
        let suite = "coucou-glance-defaults-\(ProcessInfo.processInfo.processIdentifier)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        defer { store.removePersistentDomain(forName: suite) }
        check("on at first: the meeting, the CI dot and Grok Bot",
              GlanceSettings.enabled(store) == [.meeting, .ci, .grokBot])
        check("three items at first", GlanceSettings.maxItems(store) == 3)
        store.set(true, forKey: GlanceKind.jira.enabledKey)
        store.set(false, forKey: GlanceKind.meeting.enabledKey)
        check("the user's switches win", GlanceSettings.enabled(store) == [.jira, .ci, .grokBot])
        store.set(2, forKey: GlanceSettings.maxKey)
        check("two items", GlanceSettings.maxItems(store) == 2)
        store.set(9, forKey: GlanceSettings.maxKey)
        check("never more than three", GlanceSettings.maxItems(store) == 3)
        store.set(0, forKey: GlanceSettings.maxKey)
        check("never fewer than two", GlanceSettings.maxItems(store) == 2)

        var input = quiet()
        input.grokApprovals = 1
        check("with the defaults, Jira, usage and Slack stay out",
              shown(input, enabled: [.meeting, .ci, .grokBot]) == [.ci, .meeting, .grokBot])
        check("nothing on, nothing shown", shown(input, enabled: []).isEmpty)
    }

    // MARK: - Items

    static func emptyItems() {
        section("Nothing to show is hidden")
        var empty = GlanceInputs()
        empty.pills = allPills
        check("no data, no item", Glance.items(empty, now: now).isEmpty)
        check("an empty key is no key", {
            var i = empty
            i.jiraKey = ""
            return item(.jira, i) == nil
        }())
        var off = quiet()
        off.pills = []
        off.grokApprovals = 1
        off.reviewCount = 2
        check("a pill that is off has no item", Glance.items(off, now: now).isEmpty)
        check("every kind has an item when there is data", Set(Glance.items(quiet(), now: now).map(\.kind)) == allKinds)
        check("each item opens its own pill",
              Glance.items(quiet(), now: now).allSatisfy { allPills.contains($0.pillId) })
    }

    static func ciItem() {
        section("CI dot")
        var input = GlanceInputs()
        input.pills = allPills
        input.myPRs = [pr(1, .failing, ageHours: 50), pr(2, .passing, ageHours: 2), pr(3, .running, ageHours: 9)]
        check("the newest open pull request speaks",
              item(.ci, input)?.content == .ci(checks: .passing, reviews: 0))
        check("it opens My PRs", item(.ci, input)?.pillId == "integration_prs")
        input.reviewCount = 2
        check("the reviews waiting are counted", item(.ci, input)?.content == .ci(checks: .passing, reviews: 2))
        check("and the click goes to them", item(.ci, input)?.pillId == "integration_reviews")
        input.myPRs = [pr(4, .failing, ageHours: 1)]
        check("a failing pull request comes before the reviews", item(.ci, input)?.pillId == "integration_prs")
        input.myPRs = [pr(5, .noChecks, ageHours: 1)]
        input.reviewCount = 0
        check("no checks and no review: nothing", item(.ci, input) == nil)
        input.myPRs = [pr(6, nil, ageHours: 1)]
        check("checks not read yet: nothing", item(.ci, input) == nil)
        input.reviewCount = 1
        check("reviews alone show", item(.ci, input)?.content == .ci(checks: nil, reviews: 1))
        input.pills = ["integration_reviews"]
        input.myPRs = [pr(7, .failing, ageHours: 1)]
        check("with My PRs off, its checks are not said", item(.ci, input)?.content == .ci(checks: nil, reviews: 1))
        input.pills = ["integration_prs"]
        check("with Reviews off, no count", item(.ci, input)?.content == .ci(checks: .failing, reviews: 0))
    }

    static func meetingItem() {
        section("Meeting")
        var input = GlanceInputs()
        input.pills = allPills
        func at(_ start: Double, _ length: Double = 30) -> GlanceItem? {
            input.meeting = meeting(start, length)
            return item(.meeting, input)
        }
        check("minutes are rounded up",
              at(11.2)?.content == .meeting(start: now.addingTimeInterval(11.2 * 60), minutes: 12))
        check("12 minutes away is later", at(12)?.rank == .meetingLater)
        check("10 minutes away is not under 10", at(10)?.rank == .meetingLater)
        check("9 minutes away is soon", at(9)?.rank == .meetingSoon)
        check("5 minutes away is not amber yet", at(5)?.isMeetingImminent == false)
        check("4 minutes away is amber", at(4)?.isMeetingImminent == true)
        check("just started: 0 minutes, soon and amber", {
            let i = at(-3)
            return i?.content == .meeting(start: now.addingTimeInterval(-180), minutes: 0)
                && i?.rank == .meetingSoon && i?.isMeetingImminent == true
        }())
        check("well under way: gone", at(-10, 60) == nil)
        check("over: gone", at(-60, 30) == nil)
        check("12 hours away still shows", at(12 * 60) != nil)
        check("further than that doesn't", at(12 * 60 + 1) == nil)
    }

    static func otherItems() {
        section("Jira, usage, Grok Bot, Slack")
        var input = quiet()
        check("a key Jira hasn't answered for has no colour",
              item(.jira, input)?.content == .jira(key: "POC-12", category: .unknown))
        input.jiraIssue = JiraIssue(key: "POC-12", summary: "Synthetic", status: "Doing", category: .inProgress)
        check("tinted by its status category",
              item(.jira, input)?.content == .jira(key: "POC-12", category: .inProgress))
        input.jiraIssue = JiraIssue(key: "POC-9", summary: "Synthetic", status: "Done", category: .done)
        check("another issue's status is not used",
              item(.jira, input)?.content == .jira(key: "POC-12", category: .unknown))

        check("the usage fraction", item(.usage, input)?.content
              == .usage(fraction: 0.4, resetsAt: now.addingTimeInterval(130 * 60)))
        input.usage = UsageResetInfo(resetsAt: now.addingTimeInterval(3600), source: .estimate)
        check("an estimate draws no ring", item(.usage, input) == nil)
        input.usage = reported(80, minutes: -1)
        check("a window already reset draws none", item(.usage, input) == nil)

        check("a new message is green", item(.grokBot, input)?.content == .grokBot(.message))
        input.grokQuestions = 1
        check("a question comes before a message", item(.grokBot, input)?.content == .grokBot(.question))
        input.grokApprovals = 1
        check("an approval comes before a question", item(.grokBot, input)?.content == .grokBot(.approval))

        input.slack = .unread
        check("unread without a count shows", item(.slack, input)?.content == .slack(.unread))
        input.slack = .none
        check("no badge, no dot", item(.slack, input) == nil)
    }

    // MARK: - Selection

    static func priorities() {
        section("Priorities")
        check("ranks are in order", [GlanceRank.approval, .question, .meetingSoon, .failingCI, .reviews,
                                     .meetingLater, .message, .ci, .slack, .jira, .usage]
            == [GlanceRank.approval, .question, .meetingSoon, .failingCI, .reviews,
                .meetingLater, .message, .ci, .slack, .jira, .usage].sorted())
        var input = quiet()
        check("quiet: meeting, message, CI", shown(input) == [.ci, .meeting, .grokBot])

        input.grokUnread = false
        check("without the message, Slack takes its place", shown(input) == [.ci, .meeting, .slack])

        input = quiet()
        input.grokApprovals = 1
        input.meeting = meeting(5)
        input.myPRs = [pr(1, .failing, ageHours: 1)]
        check("approval, meeting soon, failing CI", shown(input) == [.ci, .meeting, .grokBot])
        check("two places: the approval and the meeting", shown(input, max: 2) == [.meeting, .grokBot])
        check("an approval comes before a meeting",
              shown(input, enabled: [.grokBot, .meeting], max: 2) == [.meeting, .grokBot])

        input.grokApprovals = 0
        input.grokUnread = false
        input.meeting = meeting(40)
        input.myPRs = [pr(1, .passing, ageHours: 1)]
        input.reviewCount = 3
        check("reviews come before a later meeting and the rest", shown(input, max: 2) == [.ci, .meeting])
        input.grokQuestions = 1
        input.meeting = meeting(8)
        check("a question and a close meeting come before reviews", shown(input, max: 2) == [.meeting, .grokBot])

        input = quiet()
        input.meeting = meeting(60)
        input.grokUnread = false
        input.slack = .none
        check("the rest: meeting, CI, then Jira before usage", shown(input) == [.ci, .jira, .meeting])

        check("the order given doesn't matter", {
            let items = Glance.items(quiet(), now: now)
            return Glance.select(items.reversed(), enabled: allKinds, max: 3, doNotDisturb: false)
                == Glance.select(items, enabled: allKinds, max: 3, doNotDisturb: false)
        }())
        check("shown in screen order: left of the notch first",
              GlanceKind.allCases.filter(\.isLeft) == [.ci, .jira]
              && Array(GlanceKind.allCases.prefix(2)) == [.ci, .jira])
    }

    static func cap() {
        section("Cap")
        let input = quiet()
        check("three at most", shown(input).count == 3)
        check("two when set", shown(input, max: 2).count == 2)
        check("a cap above 3 is 3", shown(input, max: 6).count == 3)
        check("a cap under 2 is 2", shown(input, max: 1).count == 2)
        check("fewer items than places", shown(input, enabled: [.usage]) == [.usage])
        check("a turned-off item takes no place", shown(input, enabled: [.ci, .jira, .usage], max: 2) == [.ci, .jira])
    }

    static func doNotDisturb() {
        section("Do not disturb")
        var input = quiet()
        input.myPRs = [pr(1, .failing, ageHours: 1)]
        input.reviewCount = 2
        check("only the meeting without an approval", shown(input, dnd: true) == [.meeting])
        input.grokQuestions = 1
        check("a question is not an approval", shown(input, dnd: true) == [.meeting])
        input.grokApprovals = 1
        check("approvals and meetings stay", shown(input, dnd: true) == [.meeting, .grokBot])
        check("a far meeting stays too", {
            var i = input
            i.meeting = meeting(300)
            return shown(i, dnd: true) == [.meeting, .grokBot]
        }())
        check("a turned-off meeting stays off", shown(input, enabled: [.grokBot, .ci], dnd: true) == [.grokBot])
    }

    static func visibility() {
        section("Where it shows")
        check("beside a notch, the island closed", Glance.isVisible(hasNotch: true, inCorner: false, isOpen: false))
        check("never without a notch", !Glance.isVisible(hasNotch: false, inCorner: false, isOpen: false))
        check("never with the island in a corner", !Glance.isVisible(hasNotch: true, inCorner: true, isOpen: false))
        check("never over the open island", !Glance.isVisible(hasNotch: true, inCorner: false, isOpen: true))
    }
}
