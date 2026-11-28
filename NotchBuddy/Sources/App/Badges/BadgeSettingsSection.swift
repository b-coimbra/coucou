#if !APPSTORE
import SwiftUI

/// Settings → Integrations → Unread badges: the Slack and Mail pills (their switches are the
/// ones of Active pills).
struct BadgeSettingsSection: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        GroupBox(String(localized: "badges.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "badges.toggle.slack"), isOn: pill(BadgePills.slack))
                Toggle(String(localized: "badges.toggle.mail"), isOn: pill(BadgePills.mail))
                caption(String(localized: "badges.hint"))
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { DockBadgeController.shared.refresh() }
    }

    private func pill(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.activeIntegrations.contains(id) },
            set: { on in if on != state.activeIntegrations.contains(id) { state.toggleIntegration(id) } }
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
