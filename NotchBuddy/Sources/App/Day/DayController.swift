#if !APPSTORE
import AppKit
import Combine

/// What the day pills' cards show. In memory only.
@MainActor
final class DayStore: ObservableObject {
    static let shared = DayStore()

    @Published var access = CalendarAccess.notAsked
    @Published var meeting: MeetingEvent?
    @Published var meetingsLoaded = false
    /// A meeting is about to start and its card hasn't been on screen since
    @Published var meetingUnseen = false
    @Published var timesheetDue = false
    @Published var timesheetSeen = false

    private init() {}

    /// A @Published set redraws every card, even with the same value.
    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<DayStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// Starts and stops the day features with the settings: nothing runs for one that is off.
@MainActor
final class DayController {
    static let shared = DayController()
    private var subscriptions: Set<AnyCancellable> = []

    private init() {}

    /// Called once at launch.
    func start() {
        guard subscriptions.isEmpty else { return }
        AppState.shared.$activeIntegrations
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)
        // Do not disturb. objectWillChange comes before the new value is stored: applied on
        // the next turn.
        EdgeLightSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)
        apply()
    }

    /// Brings the watchers in line with the settings. Safe to call at any time.
    func apply() {
        let active = AppState.shared.activeIntegrations
        MeetingWatcher.shared.configure(active.contains(DayPills.meeting))
        TimesheetWatcher.shared.configure(active.contains(DayPills.timesheet))
        FocusWatcher.shared.configure(DaySettings.focusFilter && EdgeLightSettings.shared.doNotDisturb)
        syncPills()
    }

    /// The meeting pill's countdown, the pills left out and the attention dots.
    func syncPills() {
        let state = AppState.shared
        if let i = state.tasks.firstIndex(where: { $0.id == DayPills.meeting }),
           let name = PillCatalog.definition(for: DayPills.meeting)?.name {
            // The countdown only: a pill's name can leave the Mac through the phone links,
            // and an event's title never does.
            let shown = DayStore.shared.meeting.map { MeetingText.countdown($0, now: Date()) } ?? name
            if state.tasks[i].name != shown { state.tasks[i].name = shown }
        }
        syncHidden()
        syncDots()
    }

    /// The timesheet pill is only there while it is due; Do not disturb leaves out more.
    func syncHidden() {
        let state = AppState.shared
        var hidden = FocusWatcher.shared.hidden()
        if state.activeIntegrations.contains(DayPills.timesheet), !DayStore.shared.timesheetDue {
            hidden.insert(DayPills.timesheet)
            // Its card goes with it.
            if state.focusId == DayPills.timesheet { state.focusId = state.mainPillId }
        }
        state.setIfChanged(\.hiddenPills, hidden)
    }

    /// The dot stays while the card hasn't been on screen. Checked after every look, because
    /// focusing the pill removes badges.
    private func syncDots() {
        let store = DayStore.shared
        if isOnScreen(DayPills.meeting) { store.setIfChanged(\.meetingUnseen, false) }
        if store.timesheetDue && isOnScreen(DayPills.timesheet) { store.setIfChanged(\.timesheetSeen, true) }
        setDot(DayPills.meeting, store.meetingUnseen)
        setDot(DayPills.timesheet, store.timesheetDue && !store.timesheetSeen)
    }

    private func isOnScreen(_ id: String) -> Bool {
        let state = AppState.shared
        return state.mode == .expanded && state.view == .overview && state.focusId == id
    }

    private func setDot(_ id: String, _ on: Bool) {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        if on {
            if state.tasks[i].pillBadge != .approval { state.tasks[i].pillBadge = .approval }
        } else if state.tasks[i].pillBadge == .approval {
            state.tasks[i].pillBadge = nil
        }
    }
}

enum MeetingText {
    /// "12 min" before the start, "Now" from then on.
    static func countdown(_ meeting: MeetingEvent, now: Date) -> String {
        guard meeting.start > now else { return String(localized: "day.meeting.now") }
        return DurationParts.of(meeting.start.timeIntervalSince(now), roundUp: true).text
    }
}

/// What a click does: opens Calendar, Grok Bot, System Settings or a validated meeting link.
@MainActor
enum DayActions {
    static let calendarBundleId = "com.apple.iCal"
    static let privacyPage = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    static func openPill(_ id: String) {
        if id == DayPills.timesheet {
            openApp(grokBotBundleId)
        } else {
            openApp(calendarBundleId)
        }
    }

    static func openApp(_ bundleId: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    /// Checked again on the way out: only an allowed meeting host is ever opened.
    static func join(_ url: URL) {
        if let safe = MeetingLink.validated(url.absoluteString) { NSWorkspace.shared.open(safe) }
    }

    static func openCalendarPrivacy() {
        if let url = URL(string: privacyPage) { NSWorkspace.shared.open(url) }
    }
}
#endif
