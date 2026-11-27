#if !APPSTORE
import SwiftUI

// MARK: - Edge Light Scene
// What the overlay shows: a comet, the continuous line, both or nothing.

@MainActor
final class EdgeLightScene: ObservableObject {
    @Published var comet: EdgeLightComet?
    @Published var continuous: EdgeLightContinuous?
    @Published var lineWidth: CGFloat = 1.5
    @Published var glowRadii: (CGFloat, CGFloat)?

    var isAnimating: Bool { comet != nil || continuous != nil }

    /// 60 fps for a comet, 30 fps for the continuous line alone
    var frameInterval: TimeInterval { comet != nil ? 1.0 / 60.0 : 1.0 / 30.0 }

    /// `time` is in seconds since the reference date, like the comet's start time
    func currentDrawItems(at time: TimeInterval) -> [EdgeLightDrawItem] {
        var items: [EdgeLightDrawItem] = []

        // Continuous base layer
        if let continuous {
            items += continuous.render(at: time, lineWidth: lineWidth, opacity: 0.8, glowRadii: glowRadii)
        }

        // Comet on top
        if let comet {
            items += comet.render(at: time, lineWidth: lineWidth, glowRadii: glowRadii)
        }

        return items
    }
}

// MARK: - Views

/// The overlay's content. The timeline only exists while something animates, so an idle
/// overlay schedules no frame at all.
struct EdgeLightView: View {
    @ObservedObject var scene: EdgeLightScene

    var body: some View {
        Group {
            if scene.isAnimating {
                TimelineView(.animation(minimumInterval: scene.frameInterval)) { context in
                    EdgeLightCanvas(items: scene.currentDrawItems(at: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                Color.clear
            }
        }
        // The line runs along the physical edges, notch included
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Draws one frame, in the coordinates of the path (origin at the top left of the screen).
struct EdgeLightCanvas: View {
    let items: [EdgeLightDrawItem]

    var body: some View {
        Canvas { context, _ in
            for item in items {
                switch item {
                case let .line(points, rgb, alpha, width, _):
                    var path = Path()
                    path.addLines(points)
                    // Butt caps: round ones would overlap between translucent segments and bead
                    context.stroke(path, with: .color(Self.color(rgb, alpha)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round))
                case let .circle(center, radius, rgb, alpha):
                    let box = CGRect(x: center.x - radius, y: center.y - radius,
                                     width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: box), with: .color(Self.color(rgb, alpha)))
                }
            }
        }
    }

    private static func color(_ rgb: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat) -> Color {
        Color(.sRGB, red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2),
              opacity: Double(max(0, min(1, alpha))))
    }
}
#endif
