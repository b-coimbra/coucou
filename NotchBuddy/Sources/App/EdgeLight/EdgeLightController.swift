#if !APPSTORE
import AppKit
import Combine

// MARK: - Edge Light Controller
// Main coordinator: geometry, overlay, triggers, settings integration.

@MainActor
final class EdgeLightController {
    static let shared = EdgeLightController()

    /// Created on first use: nothing exists while the feature is off
    private var overlay: EdgeLightOverlay?
    private var badgeMonitor: EdgeLightBadgeMonitor?
    private var screenObserver: NSObjectProtocol?
    private var settingsSubscription: AnyCancellable?
    private var settings: EdgeLightSettings { .shared }

    private init() {}

    /// Called once at launch. Settings changes apply right away from then on.
    func start() {
        guard settingsSubscription == nil else { return }

        // objectWillChange comes before the new value is stored: applied on the next turn
        settingsSubscription = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }

        apply()
    }

    /// Brings the overlay and the badge monitor in line with the settings.
    private func apply() {
        let lit = settings.enabled && !settings.doNotDisturb

        if lit && (settings.slackEnabled || settings.mailEnabled) {
            startBadgeMonitoring()
        } else {
            badgeMonitor?.stop()
            badgeMonitor = nil
        }

        guard lit else {
            overlay?.clear()
            return
        }

        if settings.continuousMode, let screen = NSScreen.main {
            let (overlay, path) = prepareOverlay(on: screen)
            overlay.startContinuous(palette: settings.continuousPalette, path: path)
        } else {
            overlay?.stopContinuous()
        }
    }

    private func startBadgeMonitoring() {
        guard badgeMonitor == nil else { return }

        badgeMonitor = EdgeLightBadgeMonitor { [weak self] source, _ in
            Task { @MainActor in
                self?.handleBadgeIncrease(source: source)
            }
        }
        badgeMonitor?.start()
    }

    /// The overlay placed on `screen`, with the path that goes with it
    private func prepareOverlay(on screen: NSScreen) -> (EdgeLightOverlay, EdgeLightPath) {
        let overlay = self.overlay ?? EdgeLightOverlay()
        self.overlay = overlay
        overlay.place(on: screen,
                      lineWidth: settings.lineWidth,
                      glowRadii: settings.glowEnabled ? (4.0, 8.0) : nil)
        return (overlay, buildPath(for: screen))
    }

    // MARK: - Path Building

    /// In the overlay's coordinates: origin at the top left of the screen, y going down
    private func buildPath(for screen: NSScreen) -> EdgeLightPath {
        // Corner radius
        let radius: CGFloat
        switch settings.cornerRadiusPreset {
        case .auto:
            radius = EdgeLightMetrics.autoCornerRadius(screenWidth: screen.frame.width,
                                                       physicalWidthMM: physicalWidthMM(of: screen))
        case .pt8: radius = 8.0
        case .pt10: radius = 10.0
        case .pt12: radius = 12.0
        case .pt14: radius = 14.0
        case .pt16: radius = 16.0
        }

        // Notch detection
        let cutout = settings.notchContourEnabled
            ? EdgeLightCutout.detect(screenFrame: screen.frame,
                                     safeAreaTop: screen.safeAreaInsets.top,
                                     leftArea: screen.auxiliaryTopLeftArea,
                                     rightArea: screen.auxiliaryTopRightArea)
            : nil

        return EdgeLightPath(
            rect: CGRect(origin: .zero, size: screen.frame.size),
            radii: (radius, radius, radius, radius),
            lineWidth: settings.lineWidth,
            notch: cutout.map { .around($0, lineWidth: settings.lineWidth) }
        )
    }

    private func physicalWidthMM(of screen: NSScreen) -> CGFloat? {
        guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return CGDisplayScreenSize(display).width
    }

    // MARK: - Triggers

    /// Something happened: lights up if the settings allow it.
    func trigger(source: EdgeLightSource) {
        guard !settings.doNotDisturb, settings.isEnabled(source: source) else { return }
        play(source)
    }

    /// The Test button: shown even with the source off or Do not disturb on.
    func preview(source: EdgeLightSource) {
        play(source)
    }

    private func play(_ source: EdgeLightSource) {
        // The screen being worked on, read each time
        guard settings.enabled, let screen = NSScreen.main else { return }

        let (overlay, path) = prepareOverlay(on: screen)
        // The continuous line follows to the comet's screen
        if settings.continuousMode && !settings.doNotDisturb {
            overlay.startContinuous(palette: settings.continuousPalette, path: path)
        }
        overlay.playComet(
            color: settings.colorHex(for: source),
            palette: settings.palette(for: source),
            path: path
        )
    }

    private func handleBadgeIncrease(source: EdgeLightBadgeSource) {
        switch source {
        case .slack:
            trigger(source: .slack)
        case .mail:
            trigger(source: .mail)
        }
    }
}

// MARK: - Edge Light Source

enum EdgeLightSource: String, CaseIterable {
    case claudeCode
    case cursor
    case codex
    case gemini
    case antigravity
    case copilot
    case muse
    case opencode
    case amp
    case hermes
    case claudeDesktop
    case grokBot
    case slack
    case mail

    /// A product name, never translated
    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .copilot: return "Copilot"
        case .muse: return "Muse"
        case .opencode: return "OpenCode"
        case .amp: return "Amp"
        case .hermes: return "Hermes"
        case .claudeDesktop: return "Claude Desktop"
        case .grokBot: return "Grok Bot"
        case .slack: return "Slack"
        case .mail: return "Mail"
        }
    }

    var defaultColor: String {
        switch self {
        case .claudeCode, .claudeDesktop: return "#D97757"
        case .cursor: return "#C0C4CC"
        case .codex: return "#2DD4BF"
        case .gemini: return "#8AB4F8"
        case .antigravity: return "#E879F9"
        case .copilot: return "#818CF8"
        case .muse: return "#38BDF8"
        case .opencode: return "#4ADE80"
        case .amp: return "#F59E0B"
        case .hermes: return "#C084FC"
        case .grokBot: return "#10B981"
        case .slack: return "#E01E5A"
        case .mail: return "#2F8CFF"
        }
    }

    /// The colors a source sweeps through, instead of a single one
    var defaultPalette: [String]? {
        switch self {
        case .slack:
            return ["#36C5F0", "#2EB67D", "#ECB22E", "#E01E5A"]
        default:
            return nil
        }
    }

    var pillId: String? {
        switch self {
        case .claudeCode: return "integration_claude"
        case .cursor: return "agent_cursor"
        case .codex: return "agent_codex"
        case .gemini: return "agent_gemini"
        case .antigravity: return "agent_antigravity"
        case .copilot: return "agent_copilot"
        case .muse: return "agent_muse"
        case .opencode: return "agent_opencode"
        case .amp: return "agent_amp"
        case .hermes: return "agent_hermes"
        case .claudeDesktop: return "agent_claude-desktop"
        case .grokBot: return "agent_grokbot"
        default: return nil
        }
    }
}
#endif
