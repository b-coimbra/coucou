#if !APPSTORE
import SwiftUI

// MARK: - Day cards (overview left card when one of the two pills is focused)
// Display only: a click opens an app, System Settings or a validated meeting link. Event
// titles are verbatim.

struct DayPillCardView: View {
    let task: AgentTask

    var body: some View {
        if task.id == DayPills.meeting {
            MeetingCardView(task: task)
        } else {
            TimesheetCardView(task: task)
        }
    }
}

// MARK: - Next meeting

private struct MeetingCardView: View {
    let task: AgentTask
    @ObservedObject private var store = DayStore.shared
    @ObservedObject private var appState = AppState.shared

    private var onScreen: Bool {
        appState.mode == .expanded && appState.view == .overview && appState.focusId == task.id
    }

    var body: some View {
        DevFlowCard(task: task) {
            switch store.access {
            case .notAsked:
                VStack(alignment: .leading, spacing: 4) {
                    DevFlowNote(text: String(localized: "day.calendar.not-asked"))
                    DayCardButton(title: String(localized: "day.calendar.allow")) {
                        MeetingWatcher.shared.requestAccess()
                    }
                }
            case .denied:
                VStack(alignment: .leading, spacing: 4) {
                    DevFlowNote(text: String(localized: "day.calendar.denied"))
                    DayCardButton(title: String(localized: "day.calendar.open-settings")) {
                        DayActions.openCalendarPrivacy()
                    }
                }
            case .granted:
                if !store.meetingsLoaded {
                    DevFlowNote(text: String(localized: "Loading…"))
                } else if let meeting = store.meeting {
                    // The minutes move on while the card is on screen.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        row(meeting, now: context.date)
                    }
                } else {
                    DevFlowNote(text: String(localized: "day.meeting.none"))
                }
            }
        }
        .onAppear {
            MeetingWatcher.shared.refresh()
            seen()
        }
        .onChange(of: onScreen) { _, _ in seen() }
    }

    private func seen() {
        if onScreen { DayController.shared.syncPills() }
    }

    private func row(_ meeting: MeetingEvent, now: Date) -> some View {
        let countdown = MeetingText.countdown(meeting, now: now)
        let headline = meeting.start > now
            ? String(format: String(localized: "day.meeting.in %@"), countdown)
            : countdown
        return VStack(alignment: .leading, spacing: 3) {
            Button { DayActions.openApp(DayActions.calendarBundleId) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: meeting.title.isEmpty ? String(localized: "day.meeting.untitled") : meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1).truncationMode(.tail)
                    Text(verbatim: "\(headline) · \(times(meeting, now: now))")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1).truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "day.meeting.open-calendar"))
            if let url = meeting.joinURL {
                DayCardButton(title: String(localized: "day.meeting.join")) { DayActions.join(url) }
                    .help(url.host() ?? "")
            }
        }
    }

    /// "14:00 – 14:30", with the weekday when it isn't today.
    private func times(_ meeting: MeetingEvent, now: Date) -> String {
        let start = Calendar.current.isDate(meeting.start, inSameDayAs: now)
            ? meeting.start.formatted(date: .omitted, time: .shortened)
            : meeting.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(start) – \(meeting.end.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Weekly timesheet

private struct TimesheetCardView: View {
    let task: AgentTask
    @ObservedObject private var appState = AppState.shared

    private var onScreen: Bool {
        appState.mode == .expanded && appState.view == .overview && appState.focusId == task.id
    }

    var body: some View {
        DevFlowCard(task: task) {
            VStack(alignment: .leading, spacing: 5) {
                DevFlowNote(text: String(localized: "day.timesheet.note"))
                HStack(spacing: 6) {
                    DayCardButton(title: String(localized: "day.timesheet.open")) {
                        DayActions.openPill(task.id)
                    }
                    DayCardButton(title: String(localized: "day.timesheet.dismiss"), quiet: true) {
                        TimesheetWatcher.shared.dismiss()
                    }
                }
            }
            // A click anywhere else on the reminder opens Grok Bot too.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { DayActions.openPill(task.id) }
        }
        .onAppear { seen() }
        .onChange(of: onScreen) { _, _ in seen() }
    }

    private func seen() {
        if onScreen { DayController.shared.syncPills() }
    }
}

/// A small capsule button of the day cards.
private struct DayCardButton: View {
    let title: String
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: quiet ? "#C5C8CD" : "#0E0F11"))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(quiet ? Color.white.opacity(0.09) : Color(hex: "#F5F6F8"))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
