import SwiftUI

// MARK: - Grok Bot card (overview left card, once Grok Bot's local state has been read)
// One line per bot with its latest message, newest first. Text is display-only (verbatim).

struct GrokBotCardView: View {
    let task: AgentTask
    @ObservedObject private var appState = AppState.shared

    private struct Row: Identifiable {
        let id: String
        let name: String
        let message: GrokBotMessage?
    }

    private var rows: [Row] {
        appState.grokBotBots.compactMap { bot -> Row? in
            guard let id = bot["id"] as? String else { return nil }
            return Row(id: id,
                       name: bot["name"] as? String ?? "Bot",
                       message: appState.grokBotLatestMessages[id])
        }
        .sorted { ($0.message?.timestampMs ?? 0) > ($1.message?.timestampMs ?? 0) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: task.color))
                    .frame(width: 7, height: 7)
                Text(task.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                Text(PillCatalog.definition(for: task.id)?.subtitle ?? "Agent")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            if rows.isEmpty {
                Text("No messages yet")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, 8)
                    .padding(.leading, 108)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rows) { row in
                            HStack(spacing: 5) {
                                Text(verbatim: row.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(hex: "#E8E9EC"))
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: 82, alignment: .leading)
                                    .layoutPriority(1)
                                Group {
                                    if let message = row.message {
                                        Text(verbatim: message.text.replacingOccurrences(of: "\n", with: " "))
                                    } else {
                                        Text("No messages yet")
                                    }
                                }
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#8E939C"))
                                .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(.top, 5)
                .padding(.leading, 108)
                .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}
