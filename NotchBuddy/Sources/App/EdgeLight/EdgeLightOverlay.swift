#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Edge Light Overlay Window
// Borderless transparent click-through overlay on all spaces, over fullscreen apps.
// Ported from Minhoca's app_mac.py overlay window behavior.

/// Never takes the keyboard or the focus, and may cover the menu bar and the notch.
private final class EdgeLightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns the window and decides when it is on screen: only while something animates.
@MainActor
final class EdgeLightOverlay {
    private let panel: EdgeLightPanel
    private let scene = EdgeLightScene()
    private var cometEnd: Task<Void, Never>?

    init() {
        panel = EdgeLightPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // Click-through
        // Over the menu bar and over Coucou's own notch windows, which go up to
        // main menu + 4 (the dragged Mochi) and would otherwise hide part of the line
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false  // Panels hide with their app by default
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let hosting = NSHostingView(rootView: EdgeLightView(scene: scene))
        hosting.sizingOptions = []  // The window keeps the screen's size
        hosting.safeAreaRegions = []
        panel.contentView = hosting
    }

    // MARK: - Animation

    /// Covers `screen`; the paths given next are in that screen's coordinates.
    func place(on screen: NSScreen, lineWidth: CGFloat, glowRadii: (CGFloat, CGFloat)?) {
        panel.setFrame(screen.frame, display: false)
        scene.lineWidth = lineWidth
        scene.glowRadii = glowRadii
    }

    func playComet(color: String, palette: [String]?, path: EdgeLightPath) {
        let comet = EdgeLightComet(
            path: path,
            color: hexToRGB(color),
            palette: palette?.map { hexToRGB($0) },
            startTime: Date.timeIntervalSinceReferenceDate,
            lapDuration: 2.0,  // 2 seconds per lap
            laps: 2,
            fadeDuration: 0.8,
            tailLength: 0.25
        )
        scene.comet = comet
        updateVisibility()

        // A new comet replaces the running one, and its end
        cometEnd?.cancel()
        cometEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(comet.totalDuration))
            guard !Task.isCancelled, let self else { return }
            self.scene.comet = nil
            self.updateVisibility()
        }
    }

    func startContinuous(palette: [String], path: EdgeLightPath) {
        guard !palette.isEmpty else { return }

        scene.continuous = EdgeLightContinuous(
            path: path,
            palette: palette.map { hexToRGB($0) },
            cycleDuration: 6.0,
            cometCount: 1,
            cometCycleDuration: 5.0,
            cometTailLength: 0.25
        )
        updateVisibility()
    }

    func stopContinuous() {
        scene.continuous = nil
        updateVisibility()
    }

    /// Stops everything and takes the window off screen.
    func clear() {
        cometEnd?.cancel()
        cometEnd = nil
        scene.comet = nil
        scene.continuous = nil
        updateVisibility()
    }

    private func updateVisibility() {
        if scene.isAnimating {
            panel.orderFrontRegardless()  // Without activating the app
        } else {
            panel.orderOut(nil)
        }
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
#endif
