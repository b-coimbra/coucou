#if !APPSTORE
import SwiftUI

/// Settings → Agents → Agent activity: one switch per feature (a pill's switch is the one of
/// Active pills), and the daily time used while the real reset time is unknown.
struct AgentsSettingsSection: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var edgeLight = EdgeLightSettings.shared
    @AppStorage(AgentSettings.resetTimeKey) private var resetTime = DailyResetTime.fallback.text
    @AppStorage(AgentSettings.cursorPingKey) private var cursorPing = true

    var body: some View {
        GroupBox(String(localized: "agents.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "agents.toggle.reset"), isOn: pill(AgentPills.usageReset))
                caption(String(localized: "agents.reset.hint"))
                DatePicker(String(localized: "agents.reset.time"), selection: time,
                           displayedComponents: .hourAndMinute)
                    .frame(maxWidth: 360, alignment: .leading)

                Divider()
                Toggle(String(localized: "agents.toggle.jobs"), isOn: pill(AgentPills.claudeJobs))
                caption(String(localized: "agents.jobs.hint"))

                Divider()
                Toggle(String(localized: "agents.toggle.cursor"), isOn: $cursorPing)
                    .onChange(of: cursorPing) { _, _ in AgentsController.shared.apply() }
                caption(String(localized: "agents.cursor.hint"))
                if cursorPing && (!edgeLight.enabled || edgeLight.doNotDisturb
                                  || !edgeLight.isEnabled(source: .cursor)) {
                    caption(String(localized: "agents.cursor.edge-light-off"))
                        .foregroundColor(.orange)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pill(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.activeIntegrations.contains(id) },
            set: { on in if on != state.activeIntegrations.contains(id) { state.toggleIntegration(id) } }
        )
    }

    /// The picker works with a date: only its hour and minute are kept.
    private var time: Binding<Date> {
        Binding(
            get: {
                let value = DailyResetTime(resetTime) ?? .fallback
                return Calendar.current.date(bySettingHour: value.hour, minute: value.minute, second: 0,
                                             of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                resetTime = DailyResetTime(hour: parts.hour ?? 18, minute: parts.minute ?? 30).text
                UsageResetWatcher.shared.refresh()
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
