#if !APPSTORE
import Foundation
import CoreGraphics

// MARK: - Edge Light Animator
// Comet animation with tapering tail + continuous alternating colors mode.
// Ported from Minhoca's LuzBorda and LinhaContinua.

/// Smoothstep ease-in-out (0..1)
private func smoothstep(_ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, x))
    return t * t * (3 - 2 * t)
}

/// Mix two colors
private func mix(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ f: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    return (
        a.0 + (b.0 - a.0) * f,
        a.1 + (b.1 - a.1) * f,
        a.2 + (b.2 - a.2) * f
    )
}

/// Color at position x (in palette steps), blended with the next one.
/// White for an empty palette or a non-finite x, where `% 0` or Int(x) would trap.
private func paletteColor(_ palette: [(CGFloat, CGFloat, CGFloat)], at x: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    guard !palette.isEmpty, x.isFinite, x >= 0, x < 1e9 else { return (1, 1, 1) }
    let i = Int(x) % palette.count
    let f = x - floor(x)
    let smoothF = f * f * (3 - 2 * f)  // Smooth color transitions
    return mix(palette[i], palette[(i + 1) % palette.count], smoothF)
}

// MARK: - Comet Animation

struct EdgeLightComet {
    let path: EdgeLightPath
    let color: (CGFloat, CGFloat, CGFloat)  // Can be single color
    let palette: [(CGFloat, CGFloat, CGFloat)]?  // Or multi-color (Slack)
    let startTime: TimeInterval
    let lapDuration: CGFloat
    let laps: Int
    let fadeDuration: CGFloat
    let tailLength: CGFloat  // Fraction of perimeter (0.25 = 25%)
    
    /// Check if animation is still active
    func isActive(at time: TimeInterval) -> Bool {
        let elapsed = time - startTime
        return elapsed < totalDuration
    }
    
    var totalDuration: TimeInterval {
        return TimeInterval(CGFloat(laps) * lapDuration + fadeDuration)
    }
    
    /// Get current animation frame: (phase 0..1 of current lap, alpha 0..1)
    func frame(at time: TimeInterval) -> (phase: CGFloat, alpha: CGFloat)? {
        guard isActive(at: time) else { return nil }
        
        // A frame can be dated slightly before the trigger
        let elapsed = max(0, CGFloat(time - startTime))
        let lapEnd = CGFloat(laps) * lapDuration

        // Phase within current lap; the comets stay at the bottom while fading out
        let phase = elapsed >= lapEnd ? 1.0 : (elapsed / lapDuration).truncatingRemainder(dividingBy: 1.0)

        // Fade in/out
        let fadeIn: CGFloat = 0.15
        var alpha: CGFloat = 1.0
        if elapsed < fadeIn {
            alpha = elapsed / fadeIn
        }
        if elapsed > lapEnd {
            alpha = max(0, 1.0 - (elapsed - lapEnd) / fadeDuration)
        }
        
        return (phase: phase, alpha: alpha)
    }
    
    /// Render comet at current time
    func render(at time: TimeInterval, lineWidth: CGFloat, glowRadii: (CGFloat, CGFloat)?) -> [EdgeLightDrawItem] {
        guard let (phase, alpha) = frame(at: time) else { return [] }
        
        let smoothPhase = smoothstep(phase)
        let perimeter = path.perimeter
        let startS = path.topCenterS  // Start at top center
        
        // Two comets moving in opposite directions
        let distance = smoothPhase * perimeter / 2.0
        
        var items: [EdgeLightDrawItem] = []
        
        for direction in [1, -1] {
            let headS = startS + CGFloat(direction) * distance
            let tailS = headS - CGFloat(direction) * tailLength * perimeter
            
            // Render comet with tail
            items += renderCometSegment(
                headS: headS,
                tailS: tailS,
                direction: direction,
                alpha: alpha,
                lineWidth: lineWidth,
                glowRadii: glowRadii,
                limitDistance: distance
            )
        }
        
        return items
    }
    
    private func renderCometSegment(headS: CGFloat, tailS: CGFloat, direction: Int,
                                    alpha: CGFloat, lineWidth: CGFloat,
                                    glowRadii: (CGFloat, CGFloat)?, limitDistance: CGFloat) -> [EdgeLightDrawItem] {
        var items: [EdgeLightDrawItem] = []
        let tailDist = abs(headS - tailS)
        guard tailDist > 0.5 else { return items }
        
        let actualTailDist = min(tailDist, limitDistance)  // Don't pass start point
        let segments = 48
        let step = actualTailDist / CGFloat(segments)
        
        // Render tail segments (back to front)
        for i in 0..<segments {
            let d0 = CGFloat(i) * step
            let d1 = CGFloat(i + 1) * step
            let fade = 1.0 - d0 / tailDist  // 1 at head -> 0 at tail end
            
            let s0 = headS - CGFloat(direction) * d1
            let s1 = headS - CGFloat(direction) * d0
            
            let points = path.sample(from: s0, to: s1, step: 4.0)
            guard points.count >= 2 else { continue }
            
            let color = colorAt(s: (s0 + s1) / 2.0)
            let w = max(0.15, lineWidth * 1.6 * fade)
            let segAlpha = alpha * pow(fade, 1.6)
            
            items.append(.line(points: points, color: color, alpha: segAlpha, width: w))
            
            // Glow on bright sections
            if let glow = glowRadii, fade > 0.55 {
                let g = (fade - 0.55) / 0.45
                items.insert(.line(points: points, color: color, alpha: 0.22 * alpha * g, width: glow.0 * fade, isGlow: true), at: 0)
                items.insert(.line(points: points, color: color, alpha: 0.10 * alpha * g, width: glow.1 * fade, isGlow: true), at: 0)
            }
        }
        
        // Head (brightest)
        let headPt = path.point(at: headS)
        let headColor = colorAt(s: headS)
        let brightColor = mix(headColor, (1, 1, 1), 0.55)
        
        if let glow = glowRadii {
            items.insert(.circle(center: headPt, radius: glow.1 / 2 + 1, color: headColor, alpha: 0.12 * alpha), at: 0)
            items.insert(.circle(center: headPt, radius: glow.0 / 2 + 0.5, color: headColor, alpha: 0.30 * alpha), at: 0)
        }
        items.append(.circle(center: headPt, radius: lineWidth * 1.1, color: brightColor, alpha: alpha))
        
        return items
    }
    
    private func colorAt(s: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        guard let palette = palette, palette.count > 1 else {
            return color
        }
        
        // Interpolate through palette based on position
        let perimeter = path.perimeter
        var fromTop = (s - path.topCenterS).truncatingRemainder(dividingBy: perimeter)
        if fromTop < 0 { fromTop += perimeter }
        let u = abs(fromTop - perimeter / 2.0) / (perimeter / 2.0)  // 1 at the top, 0 at the bottom

        return paletteColor(palette, at: u * CGFloat(palette.count))
    }
}

// MARK: - Continuous Mode

struct EdgeLightContinuous {
    let path: EdgeLightPath
    let palette: [(CGFloat, CGFloat, CGFloat)]
    let cycleDuration: CGFloat
    let segments: Int
    let cometCount: Int
    let cometCycleDuration: CGFloat
    let cometTailLength: CGFloat
    
    init(path: EdgeLightPath, palette: [(CGFloat, CGFloat, CGFloat)],
         cycleDuration: CGFloat = 6.0, segments: Int = 96,
         cometCount: Int = 1, cometCycleDuration: CGFloat = 5.0,
         cometTailLength: CGFloat = 0.25) {
        self.path = path
        self.palette = palette
        self.cycleDuration = cycleDuration
        self.segments = max(8, segments)
        self.cometCount = max(0, cometCount)
        self.cometCycleDuration = cometCycleDuration
        self.cometTailLength = cometTailLength
    }
    
    /// Render continuous alternating colors
    func render(at time: TimeInterval, lineWidth: CGFloat, opacity: CGFloat,
                glowRadii: (CGFloat, CGFloat)?) -> [EdgeLightDrawItem] {
        var items: [EdgeLightDrawItem] = []
        let perimeter = path.perimeter
        let segmentLength = perimeter / CGFloat(segments)
        
        // Base colored segments
        for i in 0..<segments {
            let s0 = CGFloat(i) * segmentLength
            let s1 = CGFloat(i + 1) * segmentLength
            let points = path.sample(from: s0, to: s1, step: 4.0)
            guard points.count >= 2 else { continue }
            
            let color = colorAt(segment: i, time: time)
            
            if let glow = glowRadii {
                items.insert(.line(points: points, color: color, alpha: 0.05 * opacity, width: glow.1, isGlow: true), at: 0)
                items.insert(.line(points: points, color: color, alpha: 0.12 * opacity, width: glow.0, isGlow: true), at: 0)
            }
            items.append(.line(points: points, color: color, alpha: opacity, width: lineWidth))
        }
        
        // Optional comets running on top
        for k in 0..<cometCount {
            let offset = CGFloat(k) / CGFloat(max(1, cometCount))
            let phase = (CGFloat(time) / cometCycleDuration + offset).truncatingRemainder(dividingBy: 1.0)
            let s = phase * perimeter
            
            items += renderComet(at: s, time: time, lineWidth: lineWidth, glowRadii: glowRadii)
        }
        
        return items
    }
    
    private func colorAt(segment: Int, time: TimeInterval) -> (CGFloat, CGFloat, CGFloat) {
        let u = CGFloat(segment) / CGFloat(segments) - CGFloat(time) / cycleDuration
        let n = CGFloat(palette.count)
        let x = (u.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * n
        return paletteColor(palette, at: x)
    }
    
    private func renderComet(at s: CGFloat, time: TimeInterval, lineWidth: CGFloat,
                            glowRadii: (CGFloat, CGFloat)?) -> [EdgeLightDrawItem] {
        var items: [EdgeLightDrawItem] = []
        let tailDist = cometTailLength * path.perimeter
        let segments = 24
        let step = tailDist / CGFloat(segments)
        
        for i in 0..<segments {
            let d0 = CGFloat(i) * step
            let d1 = CGFloat(i + 1) * step
            let fade = 1.0 - d0 / tailDist
            
            let s0 = s - d1
            let s1 = s - d0
            let points = path.sample(from: s0, to: s1, step: 4.0)
            guard points.count >= 2 else { continue }
            
            let color = mix(colorAtPosition(s: (s0 + s1) / 2.0, time: time), (1, 1, 1), 0.25)
            
            items.append(.line(points: points, color: color, alpha: pow(fade, 1.4), width: lineWidth * fade))
        }
        
        return items
    }
    
    private func colorAtPosition(s: CGFloat, time: TimeInterval) -> (CGFloat, CGFloat, CGFloat) {
        let u = s / path.perimeter - CGFloat(time) / cycleDuration
        let n = CGFloat(palette.count)
        let x = (u.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * n
        return paletteColor(palette, at: x)
    }
}

// MARK: - Draw Items

enum EdgeLightDrawItem {
    case line(points: [CGPoint], color: (CGFloat, CGFloat, CGFloat), alpha: CGFloat, width: CGFloat, isGlow: Bool = false)
    case circle(center: CGPoint, radius: CGFloat, color: (CGFloat, CGFloat, CGFloat), alpha: CGFloat)
}
#endif
