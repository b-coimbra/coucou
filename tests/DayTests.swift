import Foundation

// Pure logic of the day features (meeting links, which meeting, the 2-minute pulse, the Do
// not disturb filter, the weekly timesheet reminder). All data is synthetic; no calendar, no
// network. Run: scripts/test-day.sh

@main
enum DayTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func section(_ name: String) { print(name) }

    static func main() {
        linksAccepted()
        linksRejected()
        linkFields()
        eligibility()
        selection()
        urgency()
        pulse()
        focusFilter()
        timesheet()
        isoWeeks()
        pills()

        if failures > 0 {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
        print("\nAll tests passed.")
    }

    /// "2026-03-08T07:00:00Z" → Date
    static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static let now = utc("2026-06-10T12:00:00Z")

    /// An event starting `start` minutes from `now` and lasting `length` minutes.
    static func event(_ id: String, _ start: Double, _ length: Double = 30,
                      allDay: Bool = false, declined: Bool = false, canceled: Bool = false,
                      link: String? = nil) -> MeetingEvent {
        let from = now.addingTimeInterval(start * 60)
        return MeetingEvent(id: id, title: "Synthetic \(id)", start: from,
                            end: from.addingTimeInterval(length * 60), isAllDay: allDay,
                            isDeclined: declined, isCanceled: canceled,
                            joinURL: link.flatMap { URL(string: $0) })
    }

    // MARK: - Meeting links

    static func linksAccepted() {
        section("MeetingLink: accepted")
        for good in [
            "https://meet.google.com/abc-defg-hij",
            "https://zoom.us/j/123456789",
            "https://us02web.zoom.us/j/123456789?pwd=AbC123",
            "https://acme.zoom.us/my/room",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d",
            "https://teams.live.com/meet/123",
            "HTTPS://MEET.GOOGLE.COM/abc",
            "https://zoom.us:443/j/1",
        ] {
            check(good, MeetingLink.validated(good) != nil)
        }
    }

    static func linksRejected() {
        section("MeetingLink: rejected")
        for bad in [
            "",
            "http://meet.google.com/abc",
            "meet.google.com/abc",
            "//zoom.us/j/1",
            "zoommtg://zoom.us/join?confno=1",
            "file:///zoom.us",
            "https://meet.google.com.evil.com/abc",
            "https://zoom.us.attacker.io/j/1",
            "https://evilzoom.us/j/1",
            "https://zoom.usa/j/1",
            "https://google.com/meet",
            "https://xmeet.google.com/abc",
            "https://teams.microsoft.com.evil.example/l",
            "https://microsoft.com/l",
            "https://live.com/meet",
            "https://example.com/?u=https://zoom.us/j/1",
            "https://example.com/zoom.us",
            "https://example.com#.zoom.us",
            "https://zoom.us@evil.com/j/1",
            "https://user:secret@zoom.us/j/1",
            "https://evil.com\\@zoom.us/j/1",
            "https://zoom.us\\.evil.com/j/1",
            "https://zoom.us:8443/j/1",
            "https://zoom%2Eus/j/1",
            "https://evil.com%2F.zoom.us/j/1",
            "https://.zoom.us/j/1",
            "https://a..zoom.us/j/1",
            "https://zoom.us./j/1",
            "https://zооm.us/j/1",          // Cyrillic letters
            "https://zoom.us/j/1 https://evil.com",
            " https://zoom.us/j/1",
            "https://zoom.us/j/1\n",
            "https:zoom.us/j/1",
            "https:///zoom.us",
        ] {
            check("\(bad.debugDescription) → nil", MeetingLink.validated(bad) == nil)
        }
        check("an endless address → nil",
              MeetingLink.validated("https://zoom.us/" + String(repeating: "a", count: 3000)) == nil)
    }

    static func linkFields() {
        section("MeetingLink.find")
        func find(_ url: String? = nil, _ location: String? = nil, _ structured: String? = nil) -> String? {
            MeetingLink.find(url: url.flatMap { URL(string: $0) }, location: location,
                             structuredLocation: structured)?.absoluteString
        }
        check("the url property", find("https://zoom.us/j/1") == "https://zoom.us/j/1")
        check("the url property first",
              find("https://zoom.us/j/1", "https://meet.google.com/a") == "https://zoom.us/j/1")
        check("a refused url, a good location",
              find("https://evil.com/x", "https://meet.google.com/a") == "https://meet.google.com/a")
        check("inside a location's text",
              find(nil, "Room 4, join <https://teams.live.com/meet/9>.") == "https://teams.live.com/meet/9")
        check("a sentence's full stop", find(nil, "Join https://zoom.us/j/1.") == "https://zoom.us/j/1")
        check("two places, the allowed one",
              find(nil, "https://evil.com/a; https://zoom.us/j/2") == "https://zoom.us/j/2")
        check("the structured location", find(nil, nil, "https://zoom.us/j/3") == "https://zoom.us/j/3")
        check("a lookalike in the location", find(nil, "https://meet.google.com.evil.com/a") == nil)
        check("no scheme in the location", find(nil, "zoom.us/j/1") == nil)
        check("a room name", find(nil, "Meeting room Zoom") == nil)
        check("nothing at all", find() == nil)
    }

    // MARK: - Which meeting

    static func eligibility() {
        section("MeetingSchedule.eligible")
        let events = [
            event("allday", -60, 24 * 60, allDay: true),
            event("declined", 10, declined: true),
            event("canceled", 10, canceled: true),
            event("ended", -60, 30),
            event("ends-now", -30, 30),
            event("running", -20, 60),
            event("later", 90),
        ]
        check("only running and later ones",
              MeetingSchedule.eligible(events, now: now).map(\.id) == ["running", "later"])
    }

    static func selection() {
        section("MeetingSchedule.next")
        func next(_ events: [MeetingEvent]) -> String? { MeetingSchedule.next(events, now: now)?.id }
        check("nothing", next([]) == nil)
        check("only skipped ones", next([event("a", 5, allDay: true), event("b", -90, 30)]) == nil)
        check("the earliest to start", next([event("b", 120), event("a", 60)]) == "a")
        check("an all-day event never hides one", next([event("d", -300, 1440, allDay: true), event("a", 60)]) == "a")
        check("a declined one is passed over", next([event("a", 10, declined: true), event("b", 60)]) == "b")
        check("just started beats one in an hour", next([event("now", -3), event("later", 60)]) == "now")
        check("one in 5 minutes beats the one just started",
              next([event("now", -3), event("soon", 5)]) == "soon")
        check("one in 6 minutes doesn't", next([event("now", -3), event("soon", 6)]) == "now")
        check("a long running one gives way to the next",
              next([event("block", -120, 480), event("later", 60)]) == "later")
        check("after 10 minutes the next one shows", next([event("old", -10), event("later", 60)]) == "later")
        check("alone, the running one stays", next([event("old", -15)]) == "old")
        check("running ones only: the first to end",
              next([event("long", -60, 240), event("short", -30, 45)]) == "short")
        check("two just started: the latest", next([event("a", -8), event("b", -2)]) == "b")
        check("same start: the one with a link",
              next([event("a", 20), event("b", 20, link: "https://zoom.us/j/1")]) == "b")
        check("same start, no link: the shorter", next([event("a", 20, 60), event("b", 20, 15)]) == "b")
        check("starting now is just started", next([event("a", 0), event("b", 30)]) == "a")
    }

    static func urgency() {
        section("MeetingSchedule.isUrgent")
        func urgent(_ start: Double) -> Bool { MeetingSchedule.isUrgent([event("a", start)], now: now) }
        check("in 6 minutes: no", !urgent(6))
        check("in 5 minutes: yes", urgent(5))
        check("now: yes", urgent(0))
        check("2 minutes in: yes", urgent(-2))
        check("3 minutes in: no", !urgent(-3))
        check("declined: no", !MeetingSchedule.isUrgent([event("a", 3, declined: true)], now: now))
        check("all-day: no", !MeetingSchedule.isUrgent([event("a", 3, allDay: true)], now: now))
        check("behind a longer one: yes",
              MeetingSchedule.isUrgent([event("block", -60, 240), event("a", 4)], now: now))
    }

    // MARK: - Pulse

    static func pulse() {
        section("MeetingPulse")
        var pulse = MeetingPulse()
        let a = event("a", 10)
        func due(_ events: [MeetingEvent], _ minutes: Double) -> [String] {
            pulse.due(events, now: now.addingTimeInterval(minutes * 60)).map(\.id)
        }
        check("8 min 1 s in: not yet", due([a], 7.98).isEmpty)
        check("2 minutes before: once", due([a], 8) == ["a"])
        check("at the next tick: no more", due([a], 8.25).isEmpty)
        check("a second before the start: no more", due([a], 9.98).isEmpty)
        check("read again from the calendar: no more", due([event("a", 10)], 9).isEmpty)
        check("moved to later: a pulse of its own", due([event("a", 30)], 28.5) == ["a"])
        check("another at the same time", due([event("b", 30)], 28.5) == ["b"])
        check("same id, next occurrence", due([event("a", 90)], 88) == ["a"])
        check("started: none", due([event("late", 100)], 100).isEmpty)
        check("appears 1 minute before: once", due([event("new", 120)], 119) == ["new"])
        var other = MeetingPulse()
        check("skipped events never pulse",
              other.due([event("a", 1, allDay: true), event("b", 1, declined: true),
                         event("c", 1, canceled: true)], now: now).isEmpty)
        check("two at once, both marked",
              other.due([event("x", 1), event("y", 2)], now: now).count == 2
              && other.due([event("x", 1), event("y", 2)], now: now).isEmpty)
    }

    // MARK: - Focus filter

    static func focusFilter() {
        section("FocusFilter")
        let pills = [
            FocusPill(id: "integration_claude", isAgent: true),
            FocusPill(id: "agent_working", isAgent: true),
            FocusPill(id: "agent_approval", isAgent: true, isWaiting: true),
            FocusPill(id: "agent_badge", isAgent: true, hasApprovalBadge: true),
            FocusPill(id: "integration_claude#2", isAgent: true, isPoppedOut: true),
            FocusPill(id: "integration_prs", hasApprovalBadge: true),
            FocusPill(id: "integration_stripe"),
            FocusPill(id: "integration_meeting"),
            FocusPill(id: "integration_timesheet", hasApprovalBadge: true),
            FocusPill(id: "agent_grokbot", isAgent: true),
        ]
        let quiet = FocusFilter.hidden(pills, urgent: [], always: ["integration_claude"])
        check("waiting, badged agents and popped-out sessions stay",
              quiet == ["agent_working", "integration_prs", "integration_stripe", "integration_meeting",
                        "integration_timesheet", "agent_grokbot"])
        let urgent = FocusFilter.hidden(pills, urgent: ["integration_meeting", "agent_grokbot"],
                                        always: ["integration_claude"])
        check("a meeting about to start stays", !urgent.contains("integration_meeting"))
        check("a pending prompt stays", !urgent.contains("agent_grokbot"))
        check("news on a service pill is not urgent", urgent.contains("integration_prs"))
        check("the timesheet reminder is not urgent", urgent.contains("integration_timesheet"))
        let card = FocusFilter.hidden(pills, urgent: [], always: ["integration_claude", "integration_stripe"])
        check("the pill on the card stays", !card.contains("integration_stripe"))
        check("no pills", FocusFilter.hidden([], urgent: ["x"], always: []).isEmpty)
    }

    // MARK: - Timesheet

    static func timesheet() {
        section("TimesheetSchedule")
        let paris = TimeZone(identifier: "Europe/Paris")!
        let friday = TimesheetSchedule(weekday: 6, time: DailyResetTime(hour: 16, minute: 0))
        func due(_ date: String, _ dismissed: String? = nil, _ schedule: TimesheetSchedule? = nil) -> Bool {
            (schedule ?? friday).isDue(utc(date), dismissedWeek: dismissed, timeZone: paris)
        }
        // Paris is UTC+2 in June; 2026-06-12 is a Friday, in ISO week 24.
        check("Friday 15:59: not yet", !due("2026-06-12T13:59:59Z"))
        check("Friday 16:00: due", due("2026-06-12T14:00:00Z"))
        check("Friday 23:59: still due", due("2026-06-12T21:59:59Z"))
        check("Saturday 00:00: gone", !due("2026-06-12T22:00:00Z"))
        check("Saturday 17:00: no", !due("2026-06-13T15:00:00Z"))
        check("Thursday 17:00: no", !due("2026-06-11T15:00:00Z"))
        check("dismissed this week", !due("2026-06-12T15:00:00Z", "2026-W24"))
        check("last week's dismissal doesn't count", due("2026-06-12T15:00:00Z", "2026-W23"))
        check("back the next Friday", due("2026-06-19T14:00:00Z", "2026-W24"))
        check("same week number, another year", due("2027-06-18T14:00:00Z", "2026-W24"))
        // 2027-01-01 is a Friday of ISO week 2026-W53.
        check("New Year's Day belongs to 2026-W53", !due("2027-01-01T16:00:00Z", "2026-W53"))
        check("and shows unless dismissed", due("2027-01-01T16:00:00Z", "2026-W52"))
        check("the first Friday of 2027's weeks", due("2027-01-08T16:00:00Z", "2026-W53"))
        // The local day decides: Friday 16:00 in Paris is Friday 07:00 in Los Angeles.
        check("local time, not UTC",
              !friday.isDue(utc("2026-06-12T14:00:00Z"), dismissedWeek: nil,
                            timeZone: TimeZone(identifier: "America/Los_Angeles")!))
        let thursday = TimesheetSchedule(weekday: 5, time: DailyResetTime(hour: 9, minute: 30))
        check("another day and time", due("2026-06-11T07:30:00Z", nil, thursday))
        check("a minute before it", !due("2026-06-11T07:29:00Z", nil, thursday))
        check("not on Friday then", !due("2026-06-12T15:00:00Z", nil, thursday))
        check("changing the day after a dismissal stays quiet that week",
              !due("2026-06-11T08:00:00Z", "2026-W24", thursday))
        check("a weekday out of range → Friday",
              TimesheetSchedule(weekday: 0, time: TimesheetSchedule.fallbackTime).weekday == 6
              && TimesheetSchedule(weekday: 8, time: TimesheetSchedule.fallbackTime).weekday == 6)
        check("defaults: Friday 16:00",
              TimesheetSchedule.fallbackWeekday == 6 && TimesheetSchedule.fallbackTime.text == "16:00")
        // Clocks go forward in Paris on 2026-03-29, a Sunday.
        let sunday = TimesheetSchedule(weekday: 1, time: DailyResetTime(hour: 2, minute: 30))
        check("a time skipped by the spring change: due once the clock has jumped",
              due("2026-03-29T01:00:00Z", nil, sunday))
        check("not before the jump", !due("2026-03-29T00:59:00Z", nil, sunday))
    }

    static func isoWeeks() {
        section("TimesheetSchedule.isoWeek")
        let zone = TimeZone(identifier: "UTC")!
        func week(_ date: String) -> String { TimesheetSchedule.isoWeek(utc(date), timeZone: zone) }
        check("mid year", week("2026-06-12T12:00:00Z") == "2026-W24")
        check("padded", week("2026-01-02T12:00:00Z") == "2026-W01")
        check("Sunday ends the week", week("2026-06-14T23:59:59Z") == "2026-W24")
        check("Monday begins one", week("2026-06-15T00:00:00Z") == "2026-W25")
        check("53-week year", week("2027-01-03T12:00:00Z") == "2026-W53")
        check("rollover", week("2027-01-04T00:00:00Z") == "2027-W01")
        check("December already in next year's week 1", week("2025-12-29T12:00:00Z") == "2026-W01")
    }

    // MARK: - Pills and settings

    static func pills() {
        section("DayPills")
        check("the ids are stable", DayPills.all == ["integration_meeting", "integration_timesheet"])
        let suite = "coucou-day-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DayPills.seed(["integration_n8n"], defaults: defaults)
        check("on at first", first == ["integration_n8n", "integration_meeting", "integration_timesheet"])
        check("saved", defaults.data(forKey: "activeIntegrations") != nil)
        check("one turned off stays off",
              DayPills.seed(["integration_n8n"], defaults: defaults) == ["integration_n8n"])
        check("the setting keys",
              DaySettings.timesheetDismissedKey == "day.timesheet.dismissedWeek"
              && DaySettings.focusFilterKey == "day.focusFilter")
    }
}
