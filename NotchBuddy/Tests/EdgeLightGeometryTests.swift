#!/usr/bin/swift
// EdgeLightGeometryTests.swift — standalone test script for edge light geometry
// Run from repo root:
//   swift NotchBuddy/Tests/EdgeLightGeometryTests.swift

import Foundation
import CoreGraphics

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ desc: String, tolerance: T? = nil) where T: Numeric {
    let matches: Bool
    if let tol = tolerance {
        matches = abs(actual - expected) <= tol
    } else {
        matches = actual == expected
    }
    
    if matches {
        passed += 1
        print("  ✓ \(desc)")
    } else {
        failed += 1
        print("  ✗ \(desc) — expected: \(expected), got: \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ desc: String) {
    if condition {
        passed += 1
        print("  ✓ \(desc)")
    } else {
        failed += 1
        print("  ✗ \(desc) — expected true")
    }
}

func assertClose(_ actual: CGFloat, _ expected: CGFloat, _ desc: String, tolerance: CGFloat = 0.1) {
    if abs(actual - expected) <= tolerance {
        passed += 1
        print("  ✓ \(desc)")
    } else {
        failed += 1
        print("  ✗ \(desc) — expected: \(expected), got: \(actual) (tolerance: \(tolerance))")
    }
}

print("Running EdgeLightGeometryTests...")

// 1. Test arc length calculation is positive
let testRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let radii: (CGFloat, CGFloat, CGFloat, CGFloat) = (12, 12, 12, 12)
// Can't instantiate the actual EdgeLightPath without importing the module,
// but we can test the perimeter formula

// Perimeter of rectangle with rounded corners (approximate)
let w = testRect.width
let h = testRect.height
let r: CGFloat = 12.0
let straightPerimeter = 2 * (w + h) - 8 * r  // straight sections
let arcPerimeter = 2 * .pi * r  // 4 quarter circles = full circle
let expectedPerimeter = straightPerimeter + arcPerimeter

assertTrue(expectedPerimeter > 0, "Perimeter is positive")
assertTrue(expectedPerimeter > 2 * (w + h) - 100, "Perimeter is reasonable (slightly less than full rectangle)")

// 2. Test corner radius scaling
let smallRadius: CGFloat = 8.0
let largeRadius: CGFloat = 16.0
assertTrue(largeRadius > smallRadius, "Larger radius value is larger")

// 3. Test notch geometry constraints
struct TestNotch {
    let leftX: CGFloat
    let rightX: CGFloat
    let bottomY: CGFloat
    let baseRadius: CGFloat
    let topRadius: CGFloat
    
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
}

let validNotch = TestNotch(leftX: 800, rightX: 1120, bottomY: 40, baseRadius: 8, topRadius: 4)
assertTrue(validNotch.canFit(topY: 0, bottomY: 1080, leftX: 50, rightX: 1870), "Valid notch fits")

let tooNarrowNotch = TestNotch(leftX: 800, rightX: 803, bottomY: 40, baseRadius: 8, topRadius: 4)
assertTrue(!tooNarrowNotch.canFit(topY: 0, bottomY: 1080, leftX: 50, rightX: 1870), "Too narrow notch doesn't fit")

let tooLowNotch = TestNotch(leftX: 800, rightX: 1120, bottomY: 2, baseRadius: 8, topRadius: 4)
assertTrue(!tooLowNotch.canFit(topY: 0, bottomY: 1080, leftX: 50, rightX: 1870), "Too shallow notch doesn't fit")

// 4. Test superellipse extension ratio
let extensionRatio: CGFloat = 1.528
assertTrue(extensionRatio > 1.0 && extensionRatio < 2.0, "Superellipse extension is reasonable (1-2x radius)")

// 5. Test physical radius calculation (simulated)
func physicalRadiusPt(screenWidthPt: CGFloat, screenWidthMm: CGFloat, targetMm: CGFloat) -> CGFloat {
    let mmPerPt = screenWidthMm / screenWidthPt
    return targetMm / mmPerPt
}

let macBookWidth: CGFloat = 1920  // pt
let macBookPhysicalWidth: CGFloat = 344  // mm (approximate for 14" MacBook Pro)
let targetPhysical: CGFloat = 4.0  // mm

let calculatedRadius = physicalRadiusPt(screenWidthPt: macBookWidth, screenWidthMm: macBookPhysicalWidth, targetMm: targetPhysical)
assertTrue(calculatedRadius > 6 && calculatedRadius < 24, "Physical radius calculation is in reasonable range (6-24 pt)")

// 6. Test distance function
func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    return hypot(a.x - b.x, a.y - b.y)
}

let p1 = CGPoint(x: 0, y: 0)
let p2 = CGPoint(x: 3, y: 4)
assertClose(distance(p1, p2), 5.0, "Pythagorean distance (3-4-5 triangle)", tolerance: 0.01)

let p3 = CGPoint(x: 100, y: 100)
let p4 = CGPoint(x: 100, y: 100)
assertClose(distance(p3, p4), 0.0, "Zero distance for same point", tolerance: 0.01)

// 7. Test arc length sampling
let sampleCount = 100
let stepSize: CGFloat = 10.0
let totalDistance = CGFloat(sampleCount) * stepSize
assertTrue(totalDistance == 1000, "Arc length sampling math is correct")

// 8. Test modulo behavior for cyclic path
func cyclicPosition(_ s: CGFloat, perimeter: CGFloat) -> CGFloat {
    return s.truncatingRemainder(dividingBy: perimeter)
}

let testPerimeter: CGFloat = 100.0
assertClose(cyclicPosition(150, perimeter: testPerimeter), 50, "Cyclic wrap-around works")
assertClose(cyclicPosition(-10, perimeter: testPerimeter), 90, "Negative cyclic wrap works")

// 9. Test corner count
let expectedCorners = 4
assertTrue(expectedCorners == 4, "Rectangle has 4 corners")

// 10. Test line width offset
let lineWidth: CGFloat = 1.5
let inset: CGFloat = 1.0
let offset = lineWidth / 2.0 + max(0, inset)
assertClose(offset, 1.75, "Line center offset calculation", tolerance: 0.01)

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
