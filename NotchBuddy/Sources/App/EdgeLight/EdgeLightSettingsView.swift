#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - EdgeLightSettingsView

/// "Edge Light" section inside SettingsView.
struct EdgeLightSettingsView: View {
    @ObservedObject private var settings = EdgeLightSettings.shared
    @State private var showOtherAgents = false

    /// One row of the sources box. Claude's row covers Claude Code and Claude Desktop.
    private struct Row: Identifiable {
        let name: String
        let sources: [EdgeLightSource]
        var id: String { name }
    }

    private static let mainRows: [Row] = [
        Row(name: "Grok Bot", sources: [.grokBot]),
        Row(name: "Claude", sources: [.claudeCode, .claudeDesktop]),
        Row(name: "Cursor", sources: [.cursor]),
        Row(name: "Slack", sources: [.slack]),
        Row(name: "Mail", sources: [.mail]),
    ]

    private static let otherRows: [Row] = [
        EdgeLightSource.codex, .gemini, .antigravity, .copilot, .muse, .opencode, .amp, .hermes,
    ].map { Row(name: $0.name, sources: [$0]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            generalBox
            appearanceBox
                .disabled(!settings.enabled)
            sourcesBox
                .disabled(!settings.enabled)
        }
    }

    // MARK: - General

    private var generalBox: some View {
        GroupBox(String(localized: "edge-light.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "edge-light.enable"), isOn: $settings.enabled)
                caption("edge-light.enable.hint")
                Toggle(String(localized: "edge-light.dnd"), isOn: $settings.doNotDisturb)
                    .disabled(!settings.enabled)
                caption("edge-light.dnd.hint")
                Toggle(String(localized: "edge-light.continuous"), isOn: $settings.continuousMode)
                    .disabled(!settings.enabled)
                caption("edge-light.continuous.hint")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            .settingsAnchor("edgelight.general")
    }

    // MARK: - Appearance

    private var appearanceBox: some View {
        GroupBox(String(localized: "edge-light.appearance")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("edge-light.width")
                    Slider(value: $settings.lineWidth, in: EdgeLightSettings.lineWidthRange, step: 0.5)
                        .frame(maxWidth: 240)
                    Text(verbatim: "\(Double(settings.lineWidth).formatted(.number.precision(.fractionLength(1)))) pt")
                        .monospacedDigit()
                }
                Picker(String(localized: "edge-light.corner"), selection: $settings.cornerRadiusPreset) {
                    ForEach(CornerRadiusPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .frame(maxWidth: 360)
                caption("edge-light.corner.hint")
                Toggle(String(localized: "edge-light.glow"), isOn: $settings.glowEnabled)
                Toggle(String(localized: "edge-light.notch"), isOn: $settings.notchContourEnabled)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            .settingsAnchor("edgelight.appearance")
    }

    // MARK: - Sources

    private var sourcesBox: some View {
        GroupBox(String(localized: "edge-light.sources")) {
            VStack(alignment: .leading, spacing: 10) {
                caption("edge-light.sources.hint")
                ForEach(Self.mainRows) { sourceRow($0) }
                DisclosureGroup(String(localized: "edge-light.other-agents"), isExpanded: $showOtherAgents) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.otherRows) { sourceRow($0) }
                    }
                    .padding(.top, 8)
                }
                Divider()
                HStack {
                    Spacer()
                    Button(String(localized: "edge-light.reset-colors")) { settings.resetColors() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            .settingsAnchor("edgelight.sources")
    }

    private func sourceRow(_ row: Row) -> some View {
        let first = row.sources[0]
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { row.sources.contains { settings.isEnabled(source: $0) } },
                set: { on in row.sources.forEach { settings.setEnabled(on, source: $0) } }
            )) {
                Text(verbatim: row.name)
                    .frame(width: 120, alignment: .leading)
            }
            Spacer(minLength: 8)
            if let palette = settings.palette(for: first) {
                ForEach(palette.indices, id: \.self) { index in
                    colorPicker("\(row.name) \(index + 1)", hex: palette[index]) {
                        settings.setPaletteHex($0, at: index, for: first)
                    }
                }
            } else {
                colorPicker(row.name, hex: settings.colorHex(for: first)) { hex in
                    row.sources.forEach { settings.setColorHex(hex, for: $0) }
                }
            }
            Button(String(localized: "edge-light.test")) {
                EdgeLightController.shared.preview(source: first)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func colorPicker(_ label: String, hex: String, set: @escaping (String) -> Void) -> some View {
        ColorPicker(selection: Binding(
            get: { Color(hex: hex) },
            set: { color in
                if let hex = Self.hex(color) { set(hex) }
            }
        ), supportsOpacity: false) {
            Text(verbatim: label)
        }
        .labelsHidden()
    }

    private static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
