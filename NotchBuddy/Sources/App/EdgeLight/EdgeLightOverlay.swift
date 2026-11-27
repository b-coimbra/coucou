import AppKit
import SwiftUI

// MARK: - Edge Light Overlay Window
// Borderless transparent click-through overlay on all spaces, over fullscreen apps.
// Ported from Minhoca's app_mac.py overlay window behavior.

final class EdgeLightOverlay: @unchecked Sendable {
    private let window: NSWindow
    private let hostingView: NSView
    private var displayLink: CVDisplayLink?
    private var activeComet: EdgeLightComet?
    private var continuousAnimation: EdgeLightContinuous?
    private var lastFrameTime: TimeInterval = 0
    
    @MainActor
    init(screen: NSScreen) {
        let frame = screen.frame
        
        // Create borderless, non-activating panel
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true  // Click-through
        window.level = .statusBar  // Over regular windows
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        // Create hosting view for SwiftUI
        let contentView = EdgeLightContentView()
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        
        self.hostingView = hosting
        window.contentView = hosting
        
        self.lastFrameTime = CACurrentMediaTime()
    }
    
    @MainActor
    func show() {
        window.orderFrontRegardless()
        startDisplayLink()
    }
    
    @MainActor
    func hide() {
        window.orderOut(nil)
        stopDisplayLink()
    }
    
    @MainActor
    func updateFrame(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
    }
    
    // MARK: - Animation
    
    @MainActor
    func triggerComet(color: String, palette: [String]?, path: EdgeLightPath,
                     lineWidth: CGFloat, glowRadii: (CGFloat, CGFloat)?) {
        let rgb = hexToRGB(color)
        let paletteRGB = palette?.compactMap { hexToRGB($0) }
        
        activeComet = EdgeLightComet(
            path: path,
            color: rgb,
            palette: paletteRGB,
            startTime: CACurrentMediaTime(),
            lapDuration: 2.0,  // 2 seconds per lap
            laps: 2,
            fadeDuration: 0.8,
            tailLength: 0.25
        )
        
        show()
    }
    
    @MainActor
    func startContinuous(palette: [String], path: EdgeLightPath,
                        lineWidth: CGFloat, opacity: CGFloat,
                        glowRadii: (CGFloat, CGFloat)?) {
        let paletteRGB = palette.compactMap { hexToRGB($0) }
        guard !paletteRGB.isEmpty else { return }
        
        continuousAnimation = EdgeLightContinuous(
            path: path,
            palette: paletteRGB,
            cycleDuration: 6.0,
            cometCount: 1,
            cometCycleDuration: 5.0,
            cometTailLength: 0.25
        )
        
        show()
    }
    
    @MainActor
    func stopContinuous() {
        continuousAnimation = nil
        if activeComet == nil {
            hide()
        }
    }
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        
        guard let link = link else { return }
        
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context = context else { return kCVReturnSuccess }
            let overlay = Unmanaged<EdgeLightOverlay>.fromOpaque(context).takeUnretainedValue()
            
            Task { @MainActor in
                overlay.renderFrame()
            }
            
            return kCVReturnSuccess
        }
        
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        
        self.displayLink = link
    }
    
    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        self.displayLink = nil
    }
    
    @MainActor
    private func renderFrame() {
        let now = CACurrentMediaTime()
        
        // Check if comet finished
        if let comet = activeComet, !comet.isActive(at: now) {
            activeComet = nil
            if continuousAnimation == nil {
                hide()
            }
        }
        
        // Trigger redraw
        if activeComet != nil || continuousAnimation != nil {
            hostingView.needsDisplay = true
        }
        
        lastFrameTime = now
    }
    
    // MARK: - Drawing
    
    @MainActor
    func currentDrawItems(path: EdgeLightPath, lineWidth: CGFloat,
                         glowRadii: (CGFloat, CGFloat)?) -> [EdgeLightDrawItem] {
        let now = CACurrentMediaTime()
        var items: [EdgeLightDrawItem] = []
        
        // Continuous base layer
        if let continuous = continuousAnimation {
            items += continuous.render(at: now, lineWidth: lineWidth, opacity: 0.8, glowRadii: glowRadii)
        }
        
        // Comet on top
        if let comet = activeComet {
            items += comet.render(at: now, lineWidth: lineWidth, glowRadii: glowRadii)
        }
        
        return items
    }
}

// MARK: - SwiftUI Content View

private struct EdgeLightContentView: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private func hexToRGB(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
    
    var rgb: UInt64 = 0
    Scanner(string: hexSanitized).scanHexInt64(&rgb)
    
    let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
    let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
    let b = CGFloat(rgb & 0x0000FF) / 255.0
    
    return (r, g, b)
}
