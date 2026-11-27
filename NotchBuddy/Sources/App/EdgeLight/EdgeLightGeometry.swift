#if !APPSTORE
import Foundation
import CoreGraphics

// MARK: - Edge Light Geometry
// Continuous-curvature corner paths (Apple-style superellipse) with notch contouring.
// Ported from Minhoca (CaminhoContorno, quina_continua, caminho_linha, notch_da_tela).
// Coordinates are those of one screen: points, origin at its top left, y going down.

/// Minhoca's default values, in points.
enum EdgeLightMetrics {
    /// A corner's curve starts this many radii away from the corner, as on Apple's displays
    static let cornerExtension: CGFloat = 1.528
    /// "Auto" radius when the display's physical size is unknown
    static let fallbackCornerRadius: CGFloat = 12.5
    /// "Auto" radius on a display of known size, in millimetres
    static let autoCornerRadiusMM: CGFloat = 4.0
    static let autoCornerRadiusRange: ClosedRange<CGFloat> = 6.0...24.0
    /// Added to half the line width: the physical edge of the screen hides about 1 pt
    static let screenInset: CGFloat = 1.0
    /// The notch's bottom corners (convex), before the line's clearance is added
    static let notchBaseRadius: CGFloat = 8.0
    /// The flares where the notch meets the top edge (concave)
    static let notchTopRadius: CGFloat = 4.0
    /// Room left between the notch and the line, on top of half the line width
    static let notchGap: CGFloat = 1.0

    /// The "Auto" radius of the screen's corners.
    /// - Parameters:
    ///   - screenWidth: Width of the screen in points
    ///   - physicalWidthMM: Width of its panel (`CGDisplayScreenSize`), if known
    static func autoCornerRadius(screenWidth: CGFloat, physicalWidthMM: CGFloat?) -> CGFloat {
        // Under 100 mm the size is not to be trusted (projector, AirPlay…)
        guard let mm = physicalWidthMM, mm.isFinite, mm >= 100 else { return fallbackCornerRadius }
        let radius = autoCornerRadiusMM * screenWidth / mm
        return max(autoCornerRadiusRange.lowerBound, min(autoCornerRadiusRange.upperBound, radius))
    }
}

/// Exponent of the superellipse: its midpoint falls where a circular arc of the same
/// radius would put it
private let superellipseExponent: CGFloat = {
    let target = (1.0 - 1.0 / CGFloat(2).squareRoot()) / EdgeLightMetrics.cornerExtension
    return -1.0 / log2(1.0 - target)
}()

/// A continuous-curvature corner at `vertex`, between the straight line arriving along
/// `dirIn` and the one leaving along `dirOut`. Convex or concave alike.
/// `ext` is how far from the vertex the curve starts and ends.
private func continuousCorner(vertex: CGPoint, dirIn: (CGFloat, CGFloat), dirOut: (CGFloat, CGFloat),
                              extension ext: CGFloat, samples: Int) -> [CGPoint] {
    guard ext > 0 else { return [vertex] }

    let p = superellipseExponent
    let cx = vertex.x - dirIn.0 * ext + dirOut.0 * ext
    let cy = vertex.y - dirIn.1 * ext + dirOut.1 * ext

    return (0...samples).map { i in
        let t = (CGFloat.pi / 2.0) * CGFloat(i) / CGFloat(samples)
        let u = pow(cos(t), 2.0 / p)
        let v = pow(sin(t), 2.0 / p)
        return CGPoint(x: cx - dirOut.0 * ext * u + dirIn.0 * ext * v,
                       y: cy - dirOut.1 * ext * u + dirIn.1 * ext * v)
    }
}

// MARK: - Path

struct EdgeLightPath {
    let points: [CGPoint]
    let arcLengths: [CGFloat]  // cumulative arc lengths for each point
    let perimeter: CGFloat
    /// Arc length of the middle of the top edge (under the notch when there is one)
    let topCenterS: CGFloat
    let rect: CGRect
    let notch: EdgeLightNotch?

    /// Creates a continuous-curvature contour path around the screen edges
    /// - Parameters:
    ///   - rect: Screen bounds
    ///   - radii: The screen's corner radii (topLeft, topRight, bottomRight, bottomLeft).
    ///     The line's own radius is smaller by its distance to the edge; 0 is a square corner
    ///   - lineWidth: Width of the line (affects inset)
    ///   - inset: Additional inset from edges
    ///   - notch: The way around the notch, if any
    ///   - samplesPerCorner: Number of samples for each corner curve
    init(rect: CGRect, radii: (CGFloat, CGFloat, CGFloat, CGFloat),
         lineWidth: CGFloat, inset: CGFloat = EdgeLightMetrics.screenInset,
         notch: EdgeLightNotch? = nil, samplesPerCorner: Int = 28) {

        self.rect = rect
        self.notch = notch
        let samples = max(1, samplesPerCorner)  // 0...negative traps, 0 divides by zero

        // The center of the line: half its width plus the inset from the real edge
        let offset = lineWidth / 2.0 + max(0, inset)
        let x0 = rect.minX + offset
        let y0 = rect.minY + offset
        let width = max(1, rect.width - 2 * offset)
        let height = max(1, rect.height - 2 * offset)
        let x1 = x0 + width
        let y1 = y0 + height

        // The line follows the screen's corner from inside: radius minus offset
        let limit = min(width, height) / 2.0
        func cornerExtent(_ radius: CGFloat) -> CGFloat {
            min(max(0, radius - offset) * EdgeLightMetrics.cornerExtension, limit)
        }
        let topLeft = cornerExtent(radii.0)
        let topRight = cornerExtent(radii.1)
        let bottomRight = cornerExtent(radii.2)
        let bottomLeft = cornerExtent(radii.3)

        // Clockwise. Top-left corner (ends on the top edge)
        var pts = continuousCorner(vertex: CGPoint(x: x0, y: y0), dirIn: (0, -1), dirOut: (1, 0),
                                   extension: topLeft, samples: samples)
        // The path starts where that corner ends
        let start = pts.count - 1

        // Top edge, with the way around the notch
        if let notch, notch.canFit(topY: y0, bottomY: y1, leftX: x0 + topLeft, rightX: x1 - topRight) {
            pts += notch.contourPoints(topY: y0, minX: x0 + topLeft, maxX: x1 - topRight,
                                       samplesPerCorner: samples)
        }

        pts += continuousCorner(vertex: CGPoint(x: x1, y: y0), dirIn: (1, 0), dirOut: (0, 1),
                                extension: topRight, samples: samples)
        pts += continuousCorner(vertex: CGPoint(x: x1, y: y1), dirIn: (0, 1), dirOut: (-1, 0),
                                extension: bottomRight, samples: samples)
        pts += continuousCorner(vertex: CGPoint(x: x0, y: y1), dirIn: (-1, 0), dirOut: (0, -1),
                                extension: bottomLeft, samples: samples)

        pts = Array(pts[start...]) + Array(pts[..<start])

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
        for i in cleaned.indices.dropFirst() {
            lengths.append(lengths.last! + distance(cleaned[i], cleaned[i-1]))
        }
        self.arcLengths = lengths
        self.perimeter = lengths.last ?? 1.0

        // The path starts on the top edge going right, so the first segment crossing
        // the middle of the screen is the top one
        var top: CGFloat = 0
        for i in cleaned.indices.dropFirst() {
            let a = cleaned[i - 1], b = cleaned[i]
            if a.x <= rect.midX && b.x >= rect.midX && b.x > a.x {
                top = lengths[i - 1] + (lengths[i] - lengths[i - 1]) * (rect.midX - a.x) / (b.x - a.x)
                break
            }
        }
        self.topCenterS = top
    }

    /// Get point at arc length s along the path (wraps around, negative s included)
    func point(at s: CGFloat) -> CGPoint {
        // A segment needs two points; a degenerate path (NaN rect or line width) has one
        guard points.count > 1, perimeter > 0 else { return points.first ?? .zero }
        var s = s.truncatingRemainder(dividingBy: perimeter)
        if s < 0 { s += perimeter }

        // Binary search for the last point at or before s: called thousands of times a frame
        var low = 0
        var high = arcLengths.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if arcLengths[mid] <= s { low = mid } else { high = mid }
        }
        let i = max(0, min(low, points.count - 2))

        let a = points[i]
        let b = points[i + 1]
        let segLen = arcLengths[i + 1] - arcLengths[i]
        let f = segLen > 0 ? (s - arcLengths[i]) / segLen : 0.0

        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Sample points along the path from s0 to s1
    func sample(from s0: CGFloat, to s1: CGFloat, step: CGFloat = 4.0) -> [CGPoint] {
        // Int(_:) traps on NaN and infinity; the cap bounds the allocation
        let count = abs(s1 - s0) / step
        let n = count.isFinite ? Int(max(1, min(count, 10_000))) : 1
        return (0...n).map { i in
            point(at: s0 + (s1 - s0) * CGFloat(i) / CGFloat(n))
        }
    }
}

// MARK: - Notch Geometry

/// The camera housing as macOS reports it.
struct EdgeLightCutout: Equatable {
    let leftX: CGFloat
    let rightX: CGFloat
    let height: CGFloat

    /// The notch of a screen, in that screen's coordinates, or nil without one.
    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame` (AppKit, y going up)
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top`
    ///   - leftArea: `NSScreen.auxiliaryTopLeftArea`
    ///   - rightArea: `NSScreen.auxiliaryTopRightArea`
    static func detect(screenFrame: CGRect, safeAreaTop: CGFloat,
                       leftArea: CGRect?, rightArea: CGRect?) -> EdgeLightCutout? {
        guard safeAreaTop > 0, let leftArea, let rightArea,
              leftArea.width > 0, rightArea.width > 0 else {
            return nil
        }

        // Documented as screen coordinates; relative to the screen, its origin is added
        let isAbsolute = leftArea.minX >= screenFrame.minX - 1 && leftArea.minX <= screenFrame.maxX
        let originX = isAbsolute ? 0 : screenFrame.minX

        // The two areas flank the notch: it is what they leave between them
        let leftX = leftArea.maxX + originX - screenFrame.minX
        let rightX = rightArea.minX + originX - screenFrame.minX

        // The area's own height when it agrees with the safe area
        let height = [screenFrame.maxY - leftArea.minY, screenFrame.height - leftArea.minY]
            .first { $0 > 0 && $0 <= safeAreaTop + 4 } ?? safeAreaTop

        guard rightX - leftX >= 20, leftX > 0, rightX < screenFrame.width else { return nil }

        return EdgeLightCutout(leftX: leftX, rightX: rightX, height: height)
    }
}

/// The way around the notch: the lines the center of the stroke follows, and its radii.
struct EdgeLightNotch {
    let leftX: CGFloat      // Where the line goes down
    let rightX: CGFloat     // Where it comes back up
    let bottomY: CGFloat    // Where it passes under the notch
    let baseRadius: CGFloat // Radius for bottom corners (convex)
    let topRadius: CGFloat  // Radius for top flares (concave)

    /// Keeps the whole line outside the cutout: half its width plus the gap, on the sides
    /// and below. The bottom corners grow by as much, to stay parallel to the notch's.
    static func around(_ cutout: EdgeLightCutout, lineWidth: CGFloat) -> EdgeLightNotch {
        let clearance = lineWidth / 2.0 + EdgeLightMetrics.notchGap
        return EdgeLightNotch(
            leftX: cutout.leftX - clearance,
            rightX: cutout.rightX + clearance,
            bottomY: cutout.height + clearance,
            baseRadius: EdgeLightMetrics.notchBaseRadius + clearance,
            topRadius: EdgeLightMetrics.notchTopRadius
        )
    }

    /// Check if notch fits within the available space
    func canFit(topY: CGFloat, bottomY: CGFloat, leftX: CGFloat, rightX: CGFloat) -> Bool {
        guard self.rightX - self.leftX >= 4,
              self.bottomY - topY >= 2,
              self.leftX > leftX + 1,
              self.rightX < rightX - 1,
              self.bottomY < bottomY - 4 else {
            return false
        }
        return true
    }

    /// Contour points around the notch (4 continuous-curvature corners).
    /// `minX` and `maxX` are where the top edge starts and ends.
    func contourPoints(topY: CGFloat, minX: CGFloat, maxX: CGFloat, samplesPerCorner: Int) -> [CGPoint] {
        let samples = max(1, samplesPerCorner)
        let height = bottomY - topY
        var topExt = max(0, topRadius) * EdgeLightMetrics.cornerExtension
        var baseExt = max(0, baseRadius) * EdgeLightMetrics.cornerExtension

        // Scale down if notch is too small
        if topExt + baseExt > height {
            let scale = height / (topExt + baseExt)
            topExt *= scale
            baseExt *= scale
        }
        baseExt = min(baseExt, (rightX - leftX) / 2.0)
        topExt = min(topExt, leftX - minX, maxX - rightX)

        // Left flare (concave): top edge → down
        return continuousCorner(vertex: CGPoint(x: leftX, y: topY), dirIn: (1, 0), dirOut: (0, 1),
                                extension: topExt, samples: samples)
            // Bottom left (convex)
            + continuousCorner(vertex: CGPoint(x: leftX, y: bottomY), dirIn: (0, 1), dirOut: (1, 0),
                               extension: baseExt, samples: samples)
            // Bottom right (convex)
            + continuousCorner(vertex: CGPoint(x: rightX, y: bottomY), dirIn: (1, 0), dirOut: (0, -1),
                               extension: baseExt, samples: samples)
            // Right flare (concave): up → top edge
            + continuousCorner(vertex: CGPoint(x: rightX, y: topY), dirIn: (0, -1), dirOut: (1, 0),
                               extension: topExt, samples: samples)
    }
}

// MARK: - Helpers

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}
#endif
