#if !APPSTORE
import AppKit
import Combine
import EventKit

// MARK: - Meetings
// Nothing runs while the pill is off. While on: EKEventStoreChanged, and a 15 s timer that
// moves the countdown on and reads the calendar again every 5 minutes.

@MainActor
final class MeetingWatcher {
    static let shared = MeetingWatcher()
    private static let readEvery: TimeInterval = 5 * 60

    private let reader = MeetingCalendarReader()
    private var timer: Timer?
    private var changes: NSObjectProtocol?
    private var events: [MeetingEvent] = []
    private var lastRead = Date.distantPast
    private var pulse = MeetingPulse()
    /// Counts the reads, so an older answer leaves a newer one alone
    private var reads = 0

    private(set) var isOn = false

    private init() {}

    var isUrgent: Bool { isOn && MeetingSchedule.isUrgent(events, now: Date()) }

    func configure(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            let timer = Timer(timeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { MeetingWatcher.shared.tick() }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            changes = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { MeetingWatcher.shared.refresh() }
            }
            DayStore.shared.setIfChanged(\.access, CalendarAccess.current)
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            if let changes { NotificationCenter.default.removeObserver(changes) }
            changes = nil
            reader.close()
            reads += 1
            forget()
        }
    }

    /// Only ever called from a click: the system prompt never appears on its own.
    func requestAccess() {
        guard CalendarAccess.current == .notAsked else { return refresh() }
        reader.requestAccess {
            Task { @MainActor in MeetingWatcher.shared.refresh() }
        }
    }

    /// Reads the calendar now, if the feature is on and access was given.
    func refresh() {
        guard isOn, !DemoEngine.isPollerPaused else { return }
        let access = CalendarAccess.current
        DayStore.shared.setIfChanged(\.access, access)
        guard access == .granted else {
            forget()
            DayController.shared.syncPills()
            return
        }
        lastRead = Date()
        reads += 1
        let current = reads
        reader.read(now: Date()) { events in
            Task { @MainActor in
                let watcher = MeetingWatcher.shared
                guard watcher.isOn, watcher.reads == current, let events else { return }
                watcher.events = events
                DayStore.shared.setIfChanged(\.meetingsLoaded, true)
                watcher.evaluate()
            }
        }
    }

    private func tick() {
        guard !DemoEngine.isPollerPaused else { return }
        let access = CalendarAccess.current
        // Access given or taken away in System Settings shows within one tick.
        if access != DayStore.shared.access
            || (access == .granted && abs(Date().timeIntervalSince(lastRead)) >= Self.readEvery) {
            refresh()
        } else if access == .granted {
            evaluate()
        }
    }

    private func evaluate() {
        let now = Date()
        let store = DayStore.shared
        store.setIfChanged(\.meeting, MeetingSchedule.next(events, now: now))
        if !pulse.due(events, now: now).isEmpty {
            store.setIfChanged(\.meetingUnseen, true)
            // Soft: one lap. Silent with Edge Light off or on Do not disturb.
            EdgeLightController.shared.flash(colorHex: PillCatalog.definition(for: DayPills.meeting)?.color ?? "#60A5FA")
        }
        // The dot has nothing left to say once the meeting is well under way.
        if !MeetingSchedule.isUrgent(events, now: now) { store.setIfChanged(\.meetingUnseen, false) }
        DayController.shared.syncPills()
        // The notch glance counts the minutes on this tick: it has no timer of its own.
        GlanceController.shared.refresh()
    }

    private func forget() {
        events = []
        lastRead = .distantPast
        let store = DayStore.shared
        store.setIfChanged(\.meeting, nil)
        store.setIfChanged(\.meetingsLoaded, false)
        store.setIfChanged(\.meetingUnseen, false)
    }
}

// MARK: - Weekly timesheet reminder
// Nothing runs while it is off. While on: one look a minute, and after a wake.

@MainActor
final class TimesheetWatcher {
    static let shared = TimesheetWatcher()

    private var timer: Timer?
    private var wake: NSObjectProtocol?
    private(set) var isOn = false

    private init() {}

    func configure(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            let timer = Timer(timeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { TimesheetWatcher.shared.refresh() }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            wake = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { TimesheetWatcher.shared.refresh() }
            }
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
            wake = nil
            DayStore.shared.setIfChanged(\.timesheetDue, false)
            DayStore.shared.setIfChanged(\.timesheetSeen, false)
        }
    }

    func refresh() {
        guard isOn else { return }
        let due = DaySettings.timesheet.isDue(
            Date(), dismissedWeek: UserDefaults.standard.string(forKey: DaySettings.timesheetDismissedKey),
            timeZone: .current)
        let store = DayStore.shared
        store.setIfChanged(\.timesheetDue, due)
        if !due { store.setIfChanged(\.timesheetSeen, false) }
        DayController.shared.syncPills()
    }

    /// Not shown again before next week.
    func dismiss() {
        UserDefaults.standard.set(TimesheetSchedule.isoWeek(Date(), timeZone: .current),
                                  forKey: DaySettings.timesheetDismissedKey)
        refresh()
    }
}

// MARK: - Do not disturb
// Coucou can't read macOS Focus (it takes the Communication Notifications entitlement, which
// no build of Coucou carries), so this follows Coucou's own Do not disturb switch. Pills are
// only watched while it is on.

@MainActor
final class FocusWatcher {
    static let shared = FocusWatcher()

    private var subscriptions: Set<AnyCancellable> = []
    private(set) var isOn = false

    private init() {}

    func configure(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        guard on else {
            subscriptions = []
            return
        }
        let state = AppState.shared
        let changes: [AnyPublisher<Void, Never>] = [
            state.$tasks.map { _ in }.eraseToAnyPublisher(),
            state.$focusId.map { _ in }.eraseToAnyPublisher(),
            state.$mainPillId.map { _ in }.eraseToAnyPublisher(),
            state.$pendingApproval.map { _ in }.eraseToAnyPublisher(),
            state.$pendingQuestion.map { _ in }.eraseToAnyPublisher(),
            state.$waitingQuestions.map { _ in }.eraseToAnyPublisher(),
            state.$grokBotPending.map { _ in }.eraseToAnyPublisher(),
        ]
        // @Published publishes before the value is stored: looked at on the next turn.
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { _ in DayController.shared.syncHidden() }
            .store(in: &subscriptions)
        showMainPill()
    }

    /// As Do not disturb comes on, a card that isn't urgent gives way to the main pill's.
    private func showMainPill() {
        let state = AppState.shared
        guard state.pendingApproval == nil, state.pendingQuestion == nil,
              state.mode != .expanded || state.view == .overview,
              let focus = state.focusId, focus != state.mainPillId,
              hidden(always: [state.mainPillId]).contains(focus),
              state.tasks.contains(where: { $0.id == state.mainPillId }) else { return }
        state.focusId = state.mainPillId
    }

    /// The pills to leave out now.
    func hidden() -> Set<String> {
        guard isOn else { return [] }
        let state = AppState.shared
        return hidden(always: Set([state.mainPillId, state.focusTask?.id].compactMap { $0 }))
    }

    private func hidden(always: Set<String>) -> Set<String> {
        let state = AppState.shared
        let pills = state.tasks.map { task in
            let category = PillCatalog.definition(for: task.id)?.category
            return FocusPill(
                id: task.id,
                isAgent: category.map { $0 == .workspace || $0 == .agent } ?? (task.source != .n8n),
                isWaiting: task.state == .approval || task.state == .question,
                hasApprovalBadge: task.pillBadge == .approval,
                isPoppedOut: task.id != task.pill)
        }
        var urgent = Set(state.waitingQuestions.map(\.displayPill))
        if let approval = state.pendingApproval { urgent.insert(approval.pillId) }
        if !state.grokBotPending.isEmpty { urgent.insert("agent_grokbot") }
        if MeetingWatcher.shared.isUrgent { urgent.insert(DayPills.meeting) }
        return FocusFilter.hidden(pills, urgent: urgent, always: always)
    }
}
#endif
