import Foundation
import CoreGraphics

// MARK: - Edge Light Geometry
// Continuous-curvature corner paths (Apple-style superellipse) with notch contouring.
// Ported from Minhoca's nucleo.py and minhoca.py.

/// Superellipse extension ratio (curve starts ~1.53x radius from corner, like Apple's design)
private let SUPERELLIPSE_EXTENSION: CGFloat = 1.528

/// Exponent for the superellipse curve (matches circular arc visually at midpoint)
private func superellipseExponent(extensionRatio: CGFloat = SUPERELLIPSE_EXTENSION) -> CGFloat {
    let target = (1.0 - 1.0 / sqrt(2.0)) / extensionRatio
    return -1.0 / log2(1.0 - target)
}

struct EdgeLightPath {
    let points: [CGPoint]
    let arcLengths: [CGFloat]  // cumulative arc lengths for each point
    let perimeter: CGFloat
    let rect: CGRect
    let notch: EdgeLightNotch?
    
    /// Creates a continuous-curvature contour path around the screen edges
    /// - Parameters:
    ///   - rect: Screen bounds
    ///   - radii: Corner radii (topLeft, topRight, bottomRight, bottomLeft)
    ///   - lineWidth: Width of the line (affects inset)
    ///   - inset: Additional inset from edges (default ~1pt for screen bezel)
    ///   - notch: Notch parameters if present
    ///   - samplesPerCorner: Number of samples for each corner curve
    init(rect: CGRect, radii: (CGFloat, CGFloat, CGFloat, CGFloat),
         lineWidth: CGFloat, inset: CGFloat = 1.0,
         notch: EdgeLightNotch? = nil, samplesPerCorner: Int = 28) {
        
        self.rect = rect
        self.notch = notch
        
        // Offset for line center: half width + inset
        let offset = lineWidth / 2.0 + max(0, inset)
        
        // Convert radii to extensions (superellipse parameter)
        let limit = min(rect.width, rect.height) / 2.0
        let extensions = (
            min(max(0, radii.0) * SUPERELLIPSE_EXTENSION, limit),
            min(max(0, radii.1) * SUPERELLIPSE_EXTENSION, limit),
            min(max(0, radii.2) * SUPERELLIPSE_EXTENSION, limit),
            min(max(0, radii.3) * SUPERELLIPSE_EXTENSION, limit)
        )
        
        let x0 = rect.minX + offset
        let y0 = rect.minY + offset
        let x1 = rect.maxX - offset
        let y1 = rect.maxY - offset
        
        var pts: [CGPoint] = []
        
        // Top-left corner (ends at top edge)
        if extensions.0 > 0 {
            pts += Self.superellipseCorner(
                center: CGPoint(x: x0 + extensions.0, y: y0 + extensions.0),
                extension: extensions.0,
                signs: (-1, -1),
                samples: samplesPerCorner,
                startEdge: .left
            )
        } else {
            pts.append(CGPoint(x: x0, y: y0))
        }
        
        // Top edge with notch detour if present
        if let notch = notch, notch.canFit(topY: y0, bottomY: y1, leftX: x0 + extensions.0, rightX: x1 - extensions.1) {
            pts += notch.contourPoints(topY: y0, samplesPerCorner: samplesPerCorner)
        }
        
        // Top-right corner
        if extensions.1 > 0 {
            pts += Self.superellipseCorner(
                center: CGPoint(x: x1 - extensions.1, y: y0 + extensions.1),
                extension: extensions.1,
                signs: (1, -1),
                samples: samplesPerCorner,
                startEdge: .top
            )
        }
        
        // Bottom-right corner
        if extensions.2 > 0 {
            pts += Self.superellipseCorner(
                center: CGPoint(x: x1 - extensions.2, y: y1 - extensions.2),
                extension: extensions.2,
                signs: (1, 1),
                samples: samplesPerCorner,
                startEdge: .right
            )
        }
        
        // Bottom-left corner
        if extensions.3 > 0 {
            pts += Self.superellipseCorner(
                center: CGPoint(x: x0 + extensions.3, y: y1 - extensions.3),
                extension: extensions.3,
                signs: (-1, 1),
                samples: samplesPerCorner,
                startEdge: .bottom
            )
        }
        
        // Rotate to start at end of top-left corner
        let startOffset = extensions.0 > 0 ? samplesPerCorner : 0
        if startOffset > 0 && startOffset < pts.count {
            pts = Array(pts[startOffset...]) + Array(pts[..<startOffset])
        }
        
        // Remove duplicates
        var cleaned: [CGPoint] = []
        for p in pts {
            if cleaned.isEmpty || distance(p, cleaned.last!) > 1e-9 {
                cleaned.append(p)
            }
        }
        
        // Close the loop
        if !cleaned.isEmpty && distance(cleaned.first!, cleaned.last!) > 1e-9 {
            cleaned.append(cleaned.first!)
        }
        
        self.points = cleaned
        
        // Compute cumulative arc lengths
        var lengths: [CGFloat] = [0.0]
        for i in 1..<cleaned.count {
            lengths.append(lengths.last! + distance(cleaned[i], cleaned[i-1]))
        }
        self.arcLengths = lengths
        self.perimeter = lengths.last ?? 1.0
    }
    
    /// Generate superellipse corner points (continuous curvature)
    private static func superellipseCorner(center: CGPoint, extension ext: CGFloat,
                                           signs: (CGFloat, CGFloat), samples: Int,
                                           startEdge: Edge) -> [CGPoint] {
        guard ext > 0 else { return [center] }
        
        let p = superellipseExponent()
        var points: [CGPoint] = []
        
        for i in 0...samples {
            let t = (CGFloat.pi / 2.0) * CGFloat(i) / CGFloat(samples)
            
            let (a, b): (CGFloat, CGFloat)
            let (u, v): (CGFloat, CGFloat)
            
            switch startEdge {
            case .left:  // Top-left: from left edge to top edge
                a = cos(t)
                b = sin(t)
                u = pow(a, 2.0 / p)
                v = pow(b, 2.0 / p)
                points.append(CGPoint(x: center.x - ext * u, y: center.y - ext * v))
                
            case .top:  // Top-right: from top edge to right edge
                a = sin(t)
                b = cos(t)
                u = pow(a, 2.0 / p)
                v = pow(b, 2.0 / p)
                points.append(CGPoint(x: center.x + ext * u, y: center.y - ext * v))
                
            case .right:  // Bottom-right: from right edge to bottom edge
                a = cos(t)
                b = sin(t)
                u = pow(a, 2.0 / p)
                v = pow(b, 2.0 / p)
                points.append(CGPoint(x: center.x + ext * u, y: center.y + ext * v))
                
            case .bottom:  // Bottom-left: from bottom edge to left edge
                a = sin(t)
                b = cos(t)
                u = pow(a, 2.0 / p)
                v = pow(b, 2.0 / p)
                points.append(CGPoint(x: center.x - ext * u, y: center.y + ext * v))
            }
        }
        
        return points
    }
    
    /// Get point at arc length s along the path
    func point(at s: CGFloat) -> CGPoint {
        let s = s.truncatingRemainder(dividingBy: perimeter)
        guard !points.isEmpty else { return .zero }
        
        let idx = arcLengths.firstIndex { $0 > s } ?? 1
        let i = max(0, min(idx - 1, points.count - 2))
        
        let a = points[i]
        let b = points[i + 1]
        let segLen = arcLengths[i + 1] - arcLengths[i]
        let f = segLen > 0 ? (s - arcLengths[i]) / segLen : 0.0
        
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
    
    /// Sample points along the path from s0 to s1
    func sample(from s0: CGFloat, to s1: CGFloat, step: CGFloat = 4.0) -> [CGPoint] {
        let n = max(1, Int(abs(s1 - s0) / step))
        return (0...n).map { i in
            point(at: s0 + (s1 - s0) * CGFloat(i) / CGFloat(n))
        }
    }
    
    private enum Edge {
        case left, top, right, bottom
    }
}

// MARK: - Notch Geometry

struct EdgeLightNotch {
    let leftX: CGFloat      // Left edge of notch cutout
    let rightX: CGFloat     // Right edge of notch cutout
    let bottomY: CGFloat    // Bottom of notch
    let baseRadius: CGFloat // Radius for bottom corners (convex)
    let topRadius: CGFloat  // Radius for top flares (concave)
    
    /// Check if notch fits within the available space
    func canFit(topY: CGFloat, bottomY: CGFloat, leftX: CGFloat, rightX: CGFloat) -> Bool {
        guard self.rightX - self.leftX > 4,
              self.bottomY - topY > 2,
              self.leftX > leftX + 1,
              self.rightX < rightX - 1,
              self.bottomY < bottomY - 4 else {
            return false
        }
        return true
    }
    
    /// Generate contour points around the notch (4 continuous-curvature corners)
    func contourPoints(topY: CGFloat, samplesPerCorner: Int) -> [CGPoint] {
        let height = bottomY - topY
        var topExt = max(0, topRadius) * SUPERELLIPSE_EXTENSION
        var baseExt = max(0, baseRadius) * SUPERELLIPSE_EXTENSION
        
        // Scale down if notch is too small
        if topExt + baseExt > height {
            let scale = height / (topExt + baseExt)
            topExt *= scale
            baseExt *= scale
        }
        
        baseExt = min(baseExt, (rightX - leftX) / 2.0)
        
        var points: [CGPoint] = []
        
        // Left flare (concave): edge → descend
        points += continuousCorner(
            vertex: CGPoint(x: leftX, y: topY),
            dirIn: (1, 0), dirOut: (0, 1),
            extension: topExt,
            samples: samplesPerCorner
        )
        
        // Left bottom (convex)
        points += continuousCorner(
            vertex: CGPoint(x: leftX, y: bottomY),
            dirIn: (0, 1), dirOut: (1, 0),
            extension: baseExt,
            samples: samplesPerCorner
        )
        
        // Right bottom (convex)
        points += continuousCorner(
            vertex: CGPoint(x: rightX, y: bottomY),
            dirIn: (1, 0), dirOut: (0, -1),
            extension: baseExt,
            samples: samplesPerCorner
        )
        
        // Right flare (concave): ascend → edge
        points += continuousCorner(
            vertex: CGPoint(x: rightX, y: topY),
            dirIn: (0, -1), dirOut: (1, 0),
            extension: topExt,
            samples: samplesPerCorner
        )
        
        return points
    }
    
    /// Generic continuous-curvature corner (works for concave and convex)
    private func continuousCorner(vertex: CGPoint, dirIn: (CGFloat, CGFloat),
                                 dirOut: (CGFloat, CGFloat), extension ext: CGFloat,
                                 samples: Int) -> [CGPoint] {
        guard ext > 0 else { return [vertex] }
        
        let p = superellipseExponent()
        let cx = vertex.x - dirIn.0 * ext + dirOut.0 * ext
        let cy = vertex.y - dirIn.1 * ext + dirOut.1 * ext
        
        var points: [CGPoint] = []
        for i in 0...samples {
            let t = (CGFloat.pi / 2.0) * CGFloat(i) / CGFloat(samples)
            let u = pow(cos(t), 2.0 / p)
            let v = pow(sin(t), 2.0 / p)
            points.append(CGPoint(
                x: cx - dirOut.0 * ext * u + dirIn.0 * ext * v,
                y: cy - dirOut.1 * ext * u + dirIn.1 * ext * v
            ))
        }
        return points
    }
}

// MARK: - Helpers

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}
