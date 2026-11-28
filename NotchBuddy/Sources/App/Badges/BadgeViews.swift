#if !APPSTORE
import SwiftUI

// MARK: - Badge card (overview left card when the Slack or Mail badge pill is focused)
// The count only: no message, sender or subject is ever read. A click opens the app.

struct BadgeCardView: View {
    let task: AgentTask
    @ObservedObject private var store = BadgeStore.shared

    var body: some View {
        if let app = BadgeApp(pillId: task.id) {
            DevFlowCard(task: task) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: summary(app))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1).truncationMode(.tail)
                    button(String(localized: "badges.open-app")) { BadgeActions.open(app) }
                }
                // A click anywhere on the card opens the app too.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { BadgeActions.open(app) }
            }
            .onAppear { DockBadgeController.shared.refresh() }
        }
    }

    private func summary(_ app: BadgeApp) -> String {
        guard let badge = store.badges[app] else { return String(localized: "Loading…") }
        switch badge {
        case .none:   return String(localized: "badges.none")
        case .unread: return String(localized: "badges.unread")
        case .count:  return String(format: String(localized: "badges.count %@"), badge.text ?? "")
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#0E0F11"))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color(hex: "#F5F6F8"))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
