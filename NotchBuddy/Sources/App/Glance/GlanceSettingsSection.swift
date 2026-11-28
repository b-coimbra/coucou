#if !APPSTORE
import SwiftUI

/// Settings → General → Notch glance: which items stand beside the closed notch.
struct GlanceSettingsSection: View {
    @ObservedObject private var state = AppState.shared
    @AppStorage(GlanceKind.ci.enabledKey) private var ci = GlanceKind.ci.onByDefault
    @AppStorage(GlanceKind.jira.enabledKey) private var jira = GlanceKind.jira.onByDefault
    @AppStorage(GlanceKind.meeting.enabledKey) private var meeting = GlanceKind.meeting.onByDefault
    @AppStorage(GlanceKind.usage.enabledKey) private var usage = GlanceKind.usage.onByDefault
    @AppStorage(GlanceKind.grokBot.enabledKey) private var grokBot = GlanceKind.grokBot.onByDefault
    @AppStorage(GlanceKind.slack.enabledKey) private var slack = GlanceKind.slack.onByDefault
    @AppStorage(GlanceSettings.maxKey) private var maxItems = GlanceSettings.defaultMax

    var body: some View {
        GroupBox(String(localized: "glance.title")) {
            VStack(alignment: .leading, spacing: 10) {
                caption(String(localized: "glance.hint"))
                row("glance.toggle.meeting", $meeting, pills: [DayPills.meeting])
                row("glance.toggle.ci", $ci, pills: [DevFlowPills.pullRequests, DevFlowPills.reviews])
                row("glance.toggle.grok", $grokBot, pills: [Glance.grokPillId])
                row("glance.toggle.jira", $jira, pills: [DevFlowPills.jira])
                row("glance.toggle.usage", $usage, pills: [AgentPills.usageReset])
                row("glance.toggle.slack", $slack, pills: [BadgePills.slack])
                Picker(String(localized: "glance.max"), selection: $maxItems) {
                    ForEach(Array(GlanceSettings.maxRange), id: \.self) { n in
                        Text(verbatim: n.formatted()).tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360, alignment: .leading)
                caption(String(localized: "glance.priority"))
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: [ci, jira, meeting, usage, grokBot, slack]) { _, _ in GlanceController.shared.apply() }
        .onChange(of: maxItems) { _, _ in GlanceController.shared.apply() }
    }

    /// A switch, with a warning while every pill it reads from is off.
    @ViewBuilder private func row(_ key: String.LocalizationValue, _ isOn: Binding<Bool>, pills: [String]) -> some View {
        Toggle(String(localized: key), isOn: isOn)
        if isOn.wrappedValue && !pills.contains(where: { id in state.tasks.contains { $0.id == id } }) {
            let names = pills.compactMap { PillCatalog.definition(for: $0)?.name }.joined(separator: ", ")
            caption(String(format: String(localized: "glance.needs-pill %@"), names))
                .foregroundColor(.orange)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
