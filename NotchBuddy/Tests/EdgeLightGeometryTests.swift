// EdgeLightGeometryTests.swift — standalone tests for the edge light geometry
// Compiled with the app's geometry file. Run from the repo root:
//   swiftc -swift-version 6 -strict-concurrency=complete \
//     NotchBuddy/Sources/App/EdgeLight/EdgeLightGeometry.swift \
//     NotchBuddy/Tests/EdgeLightGeometryTests.swift \
//     -o /tmp/edge-light-geometry-tests && /tmp/edge-light-geometry-tests

import Foundation
import CoreGraphics

@main
@MainActor
struct EdgeLightGeometryTests {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ desc: String) {
        if condition {
            passed += 1
            print("  ✓ \(desc)")
        } else {
            failed += 1
            print("  ✗ \(desc)")
        }
    }

    static func checkClose(_ actual: CGFloat, _ expected: CGFloat, _ desc: String,
                           tolerance: CGFloat = 0.001) {
        check(abs(actual - expected) <= tolerance, "\(desc) (expected \(expected), got \(actual))")
    }

    static func has(_ path: EdgeLightPath, _ x: CGFloat, _ y: CGFloat) -> Bool {
        path.points.contains { hypot($0.x - x, $0.y - y) < 0.001 }
    }

    /// Every point matched by its reflection across the vertical line at `axis`
    static func isMirrored(_ points: [CGPoint], about axis: CGFloat) -> Bool {
        !points.isEmpty && points.allSatisfy { p in
            points.contains { hypot($0.x - (2 * axis - p.x), $0.y - p.y) < 0.001 }
        }
    }

    static func isClosed(_ path: EdgeLightPath) -> Bool {
        guard let first = path.points.first, let last = path.points.last else { return false }
        return path.points.count > 2 && hypot(first.x - last.x, first.y - last.y) < 1e-9
    }

    /// Longest stretch between two points that is neither horizontal nor vertical:
    /// a break between a curve and the next line would show up as a long slanted one
    static func longestSlant(_ path: EdgeLightPath) -> CGFloat {
        zip(path.points, path.points.dropFirst()).reduce(0) { longest, pair in
            let (a, b) = pair
            let straight = abs(a.x - b.x) < 0.001 || abs(a.y - b.y) < 0.001
            return straight ? longest : max(longest, hypot(a.x - b.x, a.y - b.y))
        }
    }

    static func main() {
        print("Running EdgeLightGeometryTests...")

        let k = EdgeLightMetrics.cornerExtension
        let lineWidth: CGFloat = 1.5
        let offset: CGFloat = 1.75  // half the line plus the 1 pt inset

        print("\nValues")
        checkClose(k, 1.528, "Extension ratio")
        checkClose(EdgeLightMetrics.fallbackCornerRadius, 12.5, "Fallback radius")
        checkClose(EdgeLightMetrics.autoCornerRadius(screenWidth: 1710, physicalWidthMM: nil), 12.5,
                   "Auto without a physical size")
        checkClose(EdgeLightMetrics.autoCornerRadius(screenWidth: 1710, physicalWidthMM: 0), 12.5,
                   "Auto with an unreliable size")
        checkClose(EdgeLightMetrics.autoCornerRadius(screenWidth: 1710, physicalWidthMM: 290.5284),
                   23.5433, "Auto on a 13-inch MacBook Air at 1710 pt: 4 mm", tolerance: 0.001)
        checkClose(EdgeLightMetrics.autoCornerRadius(screenWidth: 3840, physicalWidthMM: 150), 24,
                   "Auto is capped at 24 pt")
        checkClose(EdgeLightMetrics.autoCornerRadius(screenWidth: 800, physicalWidthMM: 800), 6,
                   "Auto is at least 6 pt")

        print("\nScreen corners")
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let r: CGFloat = 12.5
        let plain = EdgeLightPath(rect: screen, radii: (r, r, r, r), lineWidth: lineWidth)
        let ext = (r - offset) * k
        let x0 = offset, y0 = offset
        let x1 = screen.width - offset, y1 = screen.height - offset

        check(isClosed(plain), "Path is closed")
        checkClose(plain.points[0].x, x0 + ext, "Path starts 1.528 × r from the left edge")
        checkClose(plain.points[0].y, y0, "Path starts on the top edge")
        // Both ends of the four curves, 1.528 × the line's radius from each corner
        check(has(plain, x0, y0 + ext) && has(plain, x0 + ext, y0), "Top-left curve ends")
        check(has(plain, x1 - ext, y0) && has(plain, x1, y0 + ext), "Top-right curve ends")
        check(has(plain, x1, y1 - ext) && has(plain, x1 - ext, y1), "Bottom-right curve ends")
        check(has(plain, x0 + ext, y1) && has(plain, x0, y1 - ext), "Bottom-left curve ends")
        check(plain.points.allSatisfy { p in
            let onSide = abs(p.x - x0) < 0.001 || abs(p.x - x1) < 0.001
            let nearCorner = p.y < y0 + ext - 0.001 || p.y > y1 - ext + 0.001
            return !(onSide && nearCorner)
        }, "No straight side closer than 1.528 × r to a corner")
        // The midpoint of a curve falls where a circular arc of the same radius would
        let mid = x0 + (r - offset) * (1 - 1 / CGFloat(2).squareRoot())
        check(has(plain, mid, mid), "Curve midpoint matches the circular arc")
        check(isMirrored(plain.points, about: screen.midX), "Path is symmetric")
        check(longestSlant(plain) < 3, "No gap between curves and straight lines")

        let square = EdgeLightPath(rect: screen, radii: (0, 0, 0, 0), lineWidth: lineWidth)
        check(isClosed(square), "Square path is closed")
        check(has(square, x0, y0) && has(square, x1, y0) && has(square, x1, y1) && has(square, x0, y1),
              "Radius 0 keeps the four square corners")

        print("\nNotch detection")
        // As reported by a 13-inch MacBook Air at 1710 × 1112
        let cutout = EdgeLightCutout.detect(
            screenFrame: screen, safeAreaTop: 38,
            leftArea: CGRect(x: 0, y: 1074, width: 751, height: 38),
            rightArea: CGRect(x: 960, y: 1074, width: 750, height: 38))
        check(cutout == EdgeLightCutout(leftX: 751, rightX: 960, height: 38), "Built-in screen")

        // Far enough left that x = 0 can't be one of its global coordinates
        let placed = CGRect(x: -2000, y: 200, width: 1710, height: 1112)
        check(EdgeLightCutout.detect(
            screenFrame: placed, safeAreaTop: 38,
            leftArea: CGRect(x: -2000, y: 1274, width: 751, height: 38),
            rightArea: CGRect(x: -1040, y: 1274, width: 750, height: 38)) == cutout,
              "Screen away from the origin, global coordinates")
        check(EdgeLightCutout.detect(
            screenFrame: placed, safeAreaTop: 38,
            leftArea: CGRect(x: 0, y: 1074, width: 751, height: 38),
            rightArea: CGRect(x: 960, y: 1074, width: 750, height: 38)) == cutout,
              "Screen away from the origin, local coordinates")
        check(EdgeLightCutout.detect(screenFrame: screen, safeAreaTop: 0,
                                     leftArea: nil, rightArea: nil) == nil, "Screen without a notch")

        guard let cutout else {
            print("\nResults: \(passed) passed, \(failed + 1) failed")
            exit(1)
        }

        print("\nWay around the notch")
        let notch = EdgeLightNotch.around(cutout, lineWidth: lineWidth)
        checkClose(notch.leftX, 749.25, "Left side: 1.75 pt outside the cutout")
        checkClose(notch.rightX, 961.75, "Right side: 1.75 pt outside the cutout")
        checkClose(notch.bottomY, 39.75, "Bottom: 1.75 pt under the cutout")
        checkClose(notch.baseRadius, 9.75, "Bottom radius: 8 + clearance")
        checkClose(notch.topRadius, 4, "Top flare radius")

        let path = EdgeLightPath(rect: screen, radii: (r, r, r, r), lineWidth: lineWidth, notch: notch)
        let top = notch.topRadius * k
        let base = notch.baseRadius * k
        check(isClosed(path), "Path with a notch is closed")
        check(has(path, notch.leftX - top, y0) && has(path, notch.leftX, y0 + top),
              "Left flare starts 1.528 × r before the side")
        check(has(path, notch.leftX, notch.bottomY - base) && has(path, notch.leftX + base, notch.bottomY),
              "Bottom-left curve starts 1.528 × r from the corner")
        check(has(path, notch.rightX - base, notch.bottomY) && has(path, notch.rightX, notch.bottomY - base),
              "Bottom-right curve starts 1.528 × r from the corner")
        check(has(path, notch.rightX, y0 + top) && has(path, notch.rightX + top, y0),
              "Right flare ends 1.528 × r after the side")

        let center = (cutout.leftX + cutout.rightX) / 2
        let around = path.points.filter {
            $0.x >= notch.leftX - top - 0.001 && $0.x <= notch.rightX + top + 0.001 && $0.y < 100
        }
        check(isMirrored(around, about: center), "Way around is symmetric about the notch center")
        // The cutout's bottom corners are rounded: the line may cross its bounding box there
        check(path.points.allSatisfy { p in
            let inBox = p.x > cutout.leftX && p.x < cutout.rightX && p.y < cutout.height
            let inCorner = p.y > cutout.height - base
                && (p.x < cutout.leftX + base || p.x > cutout.rightX - base)
            return !inBox || inCorner
        }, "Nothing drawn inside the cutout, bottom corners aside")
        // Middle of the bottom-left curve, against a notch with 8 pt corners
        let inward = notch.baseRadius * (1 - 1 / CGFloat(2).squareRoot())
        let hardware = EdgeLightMetrics.notchBaseRadius * (1 - 1 / CGFloat(2).squareRoot())
        check(has(path, notch.leftX + inward, notch.bottomY - inward)
              && notch.leftX + inward < cutout.leftX + hardware
              && notch.bottomY - inward > cutout.height - hardware,
              "The bottom curve passes outside the notch's own")
        check(longestSlant(path) < 3, "No gap around the notch")
        let topCenter = path.point(at: path.topCenterS)
        checkClose(topCenter.x, screen.midX, "Comets start at the middle of the screen")
        checkClose(topCenter.y, notch.bottomY, "…under the notch")

        // With the notch in the middle of the screen, the whole path mirrors
        let centered = EdgeLightNotch.around(
            EdgeLightCutout(leftX: 750, rightX: 960, height: 38), lineWidth: lineWidth)
        let whole = EdgeLightPath(rect: screen, radii: (r, r, r, r), lineWidth: lineWidth, notch: centered)
        check(isMirrored(whole.points, about: 855), "Centered notch: the whole path is symmetric")

        // A notch too shallow for both curves shrinks them to fit
        let shallow = EdgeLightNotch.around(
            EdgeLightCutout(leftX: 750, rightX: 960, height: 10), lineWidth: lineWidth)
        let small = EdgeLightPath(rect: screen, radii: (r, r, r, r), lineWidth: lineWidth, notch: shallow)
        let dip = small.points.filter { $0.x > 700 && $0.x < 1010 && $0.y < 100 }
        check(isClosed(small) && !dip.isEmpty && dip.allSatisfy {
            $0.y >= y0 - 0.001 && $0.y <= shallow.bottomY + 0.001
        }, "Shallow notch stays between the top edge and its bottom")

        print("")
        print("Results: \(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }
}
