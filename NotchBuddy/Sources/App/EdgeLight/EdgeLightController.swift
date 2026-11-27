import Foundation
import AppKit

// MARK: - Edge Light Controller
// Main coordinator: geometry, overlay, triggers, settings integration.

final class EdgeLightController: @unchecked Sendable {
    static let shared = EdgeLightController()
    
    private var overlay: EdgeLightOverlay?
    private var currentPath: EdgeLightPath?
    private var badgeMonitor: EdgeLightBadgeMonitor?
    private var screenObserver: NSObjectProtocol?
    
    private init() {}
    
    @MainActor
    func start() {
        guard EdgeLightSettings.shared.enabled else { return }
        
        setupOverlay()
        setupBadgeMonitoring()
        setupScreenChangeObserver()
        
        if EdgeLightSettings.shared.continuousMode {
            startContinuous()
        }
    }
    
    @MainActor
    func stop() {
        overlay?.hide()
        badgeMonitor?.stop()
        
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }
    
    // MARK: - Setup
    
    @MainActor
    private func setupOverlay() {
        guard let screen = NSScreen.main else { return }
        
        currentPath = buildPath(for: screen)
        overlay = EdgeLightOverlay(screen: screen)
    }
    
    @MainActor
    private func setupBadgeMonitoring() {
        guard EdgeLightSettings.shared.slackEnabled || EdgeLightSettings.shared.mailEnabled else {
            return
        }
        
        badgeMonitor = EdgeLightBadgeMonitor { [weak self] source, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleBadgeIncrease(source: source)
            }
        }
        badgeMonitor?.start()
    }
    
    @MainActor
    private func setupScreenChangeObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }
    
    @MainActor
    private func handleScreenChange() {
        guard let screen = NSScreen.main else { return }
        currentPath = buildPath(for: screen)
        overlay?.updateFrame(to: screen)
    }
    
    // MARK: - Path Building
    
    @MainActor
    private func buildPath(for screen: NSScreen) -> EdgeLightPath {
        let frame = screen.frame
        let settings = EdgeLightSettings.shared
        
        // Corner radii
        let autoRadius = physicalRadiusPt(screen: screen, mm: 4.0) ?? 12.5
        let topRadius: CGFloat
        let bottomRadius: CGFloat
        
        switch settings.cornerRadiusPreset {
        case .auto:
            topRadius = autoRadius
            bottomRadius = autoRadius
        case .pt8:
            topRadius = 8.0
            bottomRadius = 8.0
        case .pt10:
            topRadius = 10.0
            bottomRadius = 10.0
        case .pt12:
            topRadius = 12.0
            bottomRadius = 12.0
        case .pt14:
            topRadius = 14.0
            bottomRadius = 14.0
        case .pt16:
            topRadius = 16.0
            bottomRadius = 16.0
        }
        
        let radii = (topRadius, topRadius, bottomRadius, bottomRadius)
        
        // Notch detection
        var notch: EdgeLightNotch? = nil
        if settings.notchContourEnabled, let detected = detectNotch(screen: screen, frame: frame) {
            notch = detected
        }
        
        return EdgeLightPath(
            rect: frame,
            radii: radii,
            lineWidth: settings.lineWidth,
            inset: 1.0,
            notch: notch
        )
    }
    
    @MainActor
    private func detectNotch(screen: NSScreen, frame: CGRect) -> EdgeLightNotch? {
        // Check for safe area insets (macOS 12+ with notch)
        guard screen.responds(to: Selector(("safeAreaInsets"))),
              screen.responds(to: Selector(("auxiliaryTopLeftArea"))),
              screen.responds(to: Selector(("auxiliaryTopRightArea"))) else {
            return nil
        }
        
        // Use Objective-C runtime to get safeAreaInsets
        let insets = screen.value(forKey: "safeAreaInsets") as? NSEdgeInsets
        guard let insets = insets, insets.top > 0 else { return nil }
        
        let leftArea = screen.value(forKey: "auxiliaryTopLeftArea") as? NSRect
        let rightArea = screen.value(forKey: "auxiliaryTopRightArea") as? NSRect
        
        guard let leftArea = leftArea, let rightArea = rightArea,
              leftArea.width > 0, rightArea.width > 0 else {
            return nil
        }
        
        let screenFrame = screen.frame
        let leftX = leftArea.maxX - frame.minX
        let rightX = rightArea.minX - frame.minX
        let bottomY = frame.minY + insets.top
        
        guard rightX - leftX > 20, leftX > 0, rightX < frame.width else {
            return nil
        }
        
        return EdgeLightNotch(
            leftX: leftX,
            rightX: rightX,
            bottomY: bottomY,
            baseRadius: 8.0,
            topRadius: 4.0
        )
    }
    
    @MainActor
    private func physicalRadiusPt(screen: NSScreen, mm: CGFloat) -> CGFloat? {
        guard let deviceDesc = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        
        let size = CGDisplayScreenSize(deviceDesc)
        guard size.width > 100 else { return nil }  // No reliable size info
        
        return max(6.0, min(24.0, mm * screen.frame.width / size.width))
    }
    
    // MARK: - Triggers
    
    @MainActor
    func trigger(source: EdgeLightSource) {
        guard EdgeLightSettings.shared.enabled,
              EdgeLightSettings.shared.isEnabled(source: source),
              let path = currentPath else {
            return
        }
        
        let settings = EdgeLightSettings.shared
        let glowRadii: (CGFloat, CGFloat)? = settings.glowEnabled ? (CGFloat(4.0), CGFloat(8.0)) : nil
        
        overlay?.triggerComet(
            color: source.color,
            palette: source.palette,
            path: path,
            lineWidth: settings.lineWidth,
            glowRadii: glowRadii
        )
    }
    
    @MainActor
    func startContinuous() {
        guard EdgeLightSettings.shared.enabled,
              EdgeLightSettings.shared.continuousMode,
              let path = currentPath else {
            return
        }
        
        let settings = EdgeLightSettings.shared
        let palette = settings.continuousPalette
        let glowRadii: (CGFloat, CGFloat)? = settings.glowEnabled ? (CGFloat(4.0), CGFloat(8.0)) : nil
        
        overlay?.startContinuous(
            palette: palette,
            path: path,
            lineWidth: settings.lineWidth,
            opacity: 0.8,
            glowRadii: glowRadii
        )
    }
    
    @MainActor
    func stopContinuous() {
        overlay?.stopContinuous()
    }
    
    @MainActor
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

enum EdgeLightSource {
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
    
    var color: String {
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
    
    var palette: [String]? {
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
