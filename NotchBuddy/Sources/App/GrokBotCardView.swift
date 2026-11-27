import AppKit
import SwiftUI

// MARK: - Grok Bot card (overview left card, once Grok Bot's local state has been read)
// Waiting prompts first, then one line per bot with its latest message, newest first.
// Text is display-only (verbatim).

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
                        ForEach(Array(appState.grokBotPending.enumerated()), id: \.offset) { _, prompt in
                            pendingRow(prompt)
                        }
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

    /// A prompt waiting in Grok Bot. A click only brings the app forward: it answers nothing.
    private func pendingRow(_ prompt: GrokBotPendingPrompt) -> some View {
        let format = switch prompt.kind {
        case .approval: String(localized: "%@ needs approval")
        case .question: String(localized: "%@ asked a question")
        }
        return Button {
            openGrokBot()
        } label: {
            HStack(alignment: .top, spacing: 5) {
                Circle()
                    .fill(Color(hex: "#F5A524"))
                    .frame(width: 5, height: 5)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: String(format: format, prompt.botName))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .lineLimit(1).truncationMode(.tail)
                    if !prompt.preview.isEmpty {
                        Text(verbatim: prompt.preview)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Launches or activates Grok Bot. No URL: nothing from the prompt is passed to it.
    private func openGrokBot() {
        #if !APPSTORE
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
        #endif
    }
}
