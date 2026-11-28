#if !APPSTORE
import SwiftUI

/// Settings → Integrations → Your day: the meeting countdown, Do not disturb and the weekly
/// timesheet reminder (a pill's switch is the one of Active pills).
struct DaySettingsSection: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var store = DayStore.shared
    @ObservedObject private var edgeLight = EdgeLightSettings.shared
    @AppStorage(DaySettings.focusFilterKey) private var focusFilter = true
    @AppStorage(DaySettings.timesheetWeekdayKey) private var weekday = TimesheetSchedule.fallbackWeekday
    @AppStorage(DaySettings.timesheetTimeKey) private var time = TimesheetSchedule.fallbackTime.text
    /// Read again whenever this page shows: it can change in System Settings.
    @State private var access = CalendarAccess.current

    var body: some View {
        GroupBox(String(localized: "day.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "day.toggle.meeting"), isOn: meetingPill)
                caption(String(localized: "day.meeting.hint"))
                if state.activeIntegrations.contains(DayPills.meeting) {
                    calendarAccess
                    if !edgeLight.enabled || edgeLight.doNotDisturb {
                        caption(String(localized: "day.meeting.edge-light-off"))
                            .foregroundColor(.orange)
                    }
                }

                Divider()
                Toggle(String(localized: "day.toggle.focus"), isOn: $focusFilter)
                    .onChange(of: focusFilter) { _, _ in DayController.shared.apply() }
                caption(String(localized: "day.focus.hint"))
                Toggle(String(localized: "day.focus.dnd"), isOn: $edgeLight.doNotDisturb)

                Divider()
                Toggle(String(localized: "day.toggle.timesheet"), isOn: pill(DayPills.timesheet))
                caption(String(localized: "day.timesheet.hint"))
                Picker(String(localized: "day.timesheet.weekday"), selection: $weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(verbatim: Calendar.current.standaloneWeekdaySymbols[day - 1]).tag(day)
                    }
                }
                .frame(maxWidth: 360, alignment: .leading)
                .onChange(of: weekday) { _, _ in TimesheetWatcher.shared.refresh() }
                DatePicker(String(localized: "day.timesheet.time"), selection: timeBinding,
                           displayedComponents: .hourAndMinute)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { access = CalendarAccess.current }
        .onChange(of: store.access) { _, new in access = new }
    }

    @ViewBuilder private var calendarAccess: some View {
        switch access {
        case .notAsked:
            Button(String(localized: "day.calendar.allow")) { MeetingWatcher.shared.requestAccess() }
        case .denied:
            caption(String(localized: "day.calendar.denied"))
                .foregroundColor(.orange)
            Button(String(localized: "day.calendar.open-settings")) { DayActions.openCalendarPrivacy() }
        case .granted:
            EmptyView()
        }
    }

    /// Turning the countdown on here asks for the calendar, once.
    private var meetingPill: Binding<Bool> {
        let base = pill(DayPills.meeting)
        return Binding(
            get: { base.wrappedValue },
            set: { on in
                base.wrappedValue = on
                if on {
                    DayController.shared.apply()
                    MeetingWatcher.shared.requestAccess()
                }
            }
        )
    }

    private func pill(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.activeIntegrations.contains(id) },
            set: { on in if on != state.activeIntegrations.contains(id) { state.toggleIntegration(id) } }
        )
    }

    /// The picker works with a date: only its hour and minute are kept.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let value = DailyResetTime(time) ?? TimesheetSchedule.fallbackTime
                return Calendar.current.date(bySettingHour: value.hour, minute: value.minute, second: 0,
                                             of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                time = DailyResetTime(hour: parts.hour ?? 16, minute: parts.minute ?? 0).text
                TimesheetWatcher.shared.refresh()
            }
        )
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
