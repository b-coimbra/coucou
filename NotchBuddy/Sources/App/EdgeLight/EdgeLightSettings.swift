import Foundation

// MARK: - Edge Light Settings
// Persistent settings for edge light feature.

final class EdgeLightSettings: ObservableObject {
    static let shared = EdgeLightSettings()
    
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "edgeLight.enabled") }
    }
    
    @Published var continuousMode: Bool {
        didSet { UserDefaults.standard.set(continuousMode, forKey: "edgeLight.continuousMode") }
    }
    
    @Published var lineWidth: CGFloat {
        didSet { UserDefaults.standard.set(lineWidth, forKey: "edgeLight.lineWidth") }
    }
    
    @Published var glowEnabled: Bool {
        didSet { UserDefaults.standard.set(glowEnabled, forKey: "edgeLight.glowEnabled") }
    }
    
    @Published var cornerRadiusPreset: CornerRadiusPreset {
        didSet { UserDefaults.standard.set(cornerRadiusPreset.rawValue, forKey: "edgeLight.cornerRadius") }
    }
    
    @Published var notchContourEnabled: Bool {
        didSet { UserDefaults.standard.set(notchContourEnabled, forKey: "edgeLight.notchContour") }
    }
    
    // Per-source toggles
    @Published var claudeCodeEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeCodeEnabled, forKey: "edgeLight.claude") }
    }
    
    @Published var cursorEnabled: Bool {
        didSet { UserDefaults.standard.set(cursorEnabled, forKey: "edgeLight.cursor") }
    }
    
    @Published var codexEnabled: Bool {
        didSet { UserDefaults.standard.set(codexEnabled, forKey: "edgeLight.codex") }
    }
    
    @Published var geminiEnabled: Bool {
        didSet { UserDefaults.standard.set(geminiEnabled, forKey: "edgeLight.gemini") }
    }
    
    @Published var antigravityEnabled: Bool {
        didSet { UserDefaults.standard.set(antigravityEnabled, forKey: "edgeLight.antigravity") }
    }
    
    @Published var copilotEnabled: Bool {
        didSet { UserDefaults.standard.set(copilotEnabled, forKey: "edgeLight.copilot") }
    }
    
    @Published var museEnabled: Bool {
        didSet { UserDefaults.standard.set(museEnabled, forKey: "edgeLight.muse") }
    }
    
    @Published var opencodeEnabled: Bool {
        didSet { UserDefaults.standard.set(opencodeEnabled, forKey: "edgeLight.opencode") }
    }
    
    @Published var ampEnabled: Bool {
        didSet { UserDefaults.standard.set(ampEnabled, forKey: "edgeLight.amp") }
    }
    
    @Published var hermesEnabled: Bool {
        didSet { UserDefaults.standard.set(hermesEnabled, forKey: "edgeLight.hermes") }
    }
    
    @Published var claudeDesktopEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeDesktopEnabled, forKey: "edgeLight.claudeDesktop") }
    }
    
    @Published var grokBotEnabled: Bool {
        didSet { UserDefaults.standard.set(grokBotEnabled, forKey: "edgeLight.grokBot") }
    }
    
    @Published var slackEnabled: Bool {
        didSet { UserDefaults.standard.set(slackEnabled, forKey: "edgeLight.slack") }
    }
    
    @Published var mailEnabled: Bool {
        didSet { UserDefaults.standard.set(mailEnabled, forKey: "edgeLight.mail") }
    }
    
    var continuousPalette: [String] {
        ["#FF3B6B", "#FF9F1C", "#FFE66D", "#2EC4B6", "#3A86FF", "#8338EC"]
    }
    
    private init() {
        let ud = UserDefaults.standard
        
        self.enabled = ud.object(forKey: "edgeLight.enabled") as? Bool ?? false
        self.continuousMode = ud.object(forKey: "edgeLight.continuousMode") as? Bool ?? false
        self.lineWidth = ud.object(forKey: "edgeLight.lineWidth") as? CGFloat ?? 1.5
        self.glowEnabled = ud.object(forKey: "edgeLight.glowEnabled") as? Bool ?? true
        self.notchContourEnabled = ud.object(forKey: "edgeLight.notchContour") as? Bool ?? true
        
        if let raw = ud.string(forKey: "edgeLight.cornerRadius"),
           let preset = CornerRadiusPreset(rawValue: raw) {
            self.cornerRadiusPreset = preset
        } else {
            self.cornerRadiusPreset = .auto
        }
        
        // Per-source defaults: all enabled by default
        self.claudeCodeEnabled = ud.object(forKey: "edgeLight.claude") as? Bool ?? true
        self.cursorEnabled = ud.object(forKey: "edgeLight.cursor") as? Bool ?? true
        self.codexEnabled = ud.object(forKey: "edgeLight.codex") as? Bool ?? true
        self.geminiEnabled = ud.object(forKey: "edgeLight.gemini") as? Bool ?? true
        self.antigravityEnabled = ud.object(forKey: "edgeLight.antigravity") as? Bool ?? true
        self.copilotEnabled = ud.object(forKey: "edgeLight.copilot") as? Bool ?? true
        self.museEnabled = ud.object(forKey: "edgeLight.muse") as? Bool ?? true
        self.opencodeEnabled = ud.object(forKey: "edgeLight.opencode") as? Bool ?? true
        self.ampEnabled = ud.object(forKey: "edgeLight.amp") as? Bool ?? true
        self.hermesEnabled = ud.object(forKey: "edgeLight.hermes") as? Bool ?? true
        self.claudeDesktopEnabled = ud.object(forKey: "edgeLight.claudeDesktop") as? Bool ?? true
        self.grokBotEnabled = ud.object(forKey: "edgeLight.grokBot") as? Bool ?? true
        self.slackEnabled = ud.object(forKey: "edgeLight.slack") as? Bool ?? true
        self.mailEnabled = ud.object(forKey: "edgeLight.mail") as? Bool ?? true
    }
    
    func isEnabled(source: EdgeLightSource) -> Bool {
        switch source {
        case .claudeCode: return claudeCodeEnabled
        case .cursor: return cursorEnabled
        case .codex: return codexEnabled
        case .gemini: return geminiEnabled
        case .antigravity: return antigravityEnabled
        case .copilot: return copilotEnabled
        case .muse: return museEnabled
        case .opencode: return opencodeEnabled
        case .amp: return ampEnabled
        case .hermes: return hermesEnabled
        case .claudeDesktop: return claudeDesktopEnabled
        case .grokBot: return grokBotEnabled
        case .slack: return slackEnabled
        case .mail: return mailEnabled
        }
    }
}

enum CornerRadiusPreset: String, CaseIterable {
    case auto = "auto"
    case pt8 = "8"
    case pt10 = "10"
    case pt12 = "12"
    case pt14 = "14"
    case pt16 = "16"
    
    var displayName: String {
        switch self {
        case .auto: return "Auto (≈4 mm)"
        case .pt8: return "8 pt"
        case .pt10: return "10 pt"
        case .pt12: return "12 pt"
        case .pt14: return "14 pt"
        case .pt16: return "16 pt"
        }
    }
}
