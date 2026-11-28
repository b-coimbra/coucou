#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Notch glance
// Small items beside the closed notch, in the island's own panel: a black wing on each side,
// flush with the resting island (or with the notch itself while the island is hidden). The
// room between the two is exactly the island's width, never less than the notch: nothing is
// drawn over the camera. The island itself is not changed.

struct GlanceNotchView: View {
    nonisolated static let space = "glancePanel"

    @ObservedObject var state: AppState
    @ObservedObject private var store = GlanceStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.allowsHitTesting(false)
            if Glance.isVisible(hasNotch: state.hasNotch, inCorner: state.islandPlacement.isCorner,
                                isOpen: state.mode == .expanded) && !store.items.isEmpty {
                // Between the wings: the notch alone (hidden), or the compact island.
                let (inner, _) = islandSize(mode: state.mode, view: state.view,
                                            nw: state.notchWidth, nh: state.notchHeight)
                HStack(spacing: 0) {
                    wing(left: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Color.clear
                        .frame(width: inner, height: state.notchHeight)
                        .allowsHitTesting(false)
                    wing(left: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder private func wing(left: Bool) -> some View {
        let items = store.items.filter { $0.kind.isLeft == left }
        if !items.isEmpty {
            // How far the black goes under the island's rounded corner, or the notch's.
            let tuck = IslandConst.roundedCorner
            HStack(spacing: 0) {
                ForEach(items) { item in
                    GlanceItemView(item: item, height: state.notchHeight,
                                   spins: state.mode != .hidden, hovered: store.hovered == item.kind)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: state.notchHeight)
            .background {
                UnevenRoundedRectangle(bottomLeadingRadius: left ? IslandConst.roundedCorner : 0,
                                       bottomTrailingRadius: left ? 0 : IslandConst.roundedCorner)
                    .fill(Color.black)
                    .padding(left ? .trailing : .leading, -tuck)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct GlanceItemView: View {
    let item: GlanceItem
    let height: CGFloat
    /// Off while the island is hidden: nothing moves then (0 % CPU).
    let spins: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .glanceOpen, object: item.pillId)
        } label: {
            content
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: GlanceText.detail(item, now: Date())))
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(GlanceNotchView.space)) }) { frame in
            GlanceStore.shared.frames[item.kind] = frame
        }
        // Under the item while the pointer is on it, like the line under Mochi.
        .overlay(alignment: .bottom) {
            if hovered {
                Text(verbatim: GlanceText.detail(item, now: Date()))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#E1E3E6"))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.92)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .offset(y: 30)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.content {
        case .ci(let checks, let reviews):
            HStack(spacing: 4) {
                if checks == .running {
                    GlanceSpinner(spinning: spins && !reduceMotion)
                        .frame(width: 9, height: 9)
                } else {
                    dot(checks == .failing ? "#F4505E" : checks == .passing ? "#22C55E" : "#8E939C")
                }
                if reviews > 0 {
                    Text(verbatim: reviews.formatted())
                        .foregroundColor(Color(hex: "#E1E3E6"))
                }
            }
        case .jira(let key, let category):
            Text(verbatim: key)
                .foregroundColor(Color(hex: jiraColor(category)))
        case .meeting(let start, let minutes):
            Text(verbatim: GlanceText.meeting(start: start, minutes: minutes))
                .foregroundColor(Color(hex: item.isMeetingImminent ? "#F5A524" : "#E1E3E6"))
        case .usage(let fraction, _):
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color(hex: ClaudePlanGauge.color(for: fraction * 100)),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
        case .grokBot(let status):
            dot(status == .message ? "#34D399" : "#F5A524")
        case .slack:
            dot(PillCatalog.definition(for: BadgePills.slack)?.color ?? "#E0407B")
        }
    }

    private func dot(_ hex: String) -> some View {
        Circle().fill(Color(hex: hex)).frame(width: 7, height: 7)
    }

    private func jiraColor(_ category: JiraIssue.Category) -> String {
        switch category {
        case .toDo:       return "#C5C8CD"
        case .inProgress: return "#4C9AFF"
        case .done:       return "#22C55E"
        case .unknown:    return "#8E939C"
        }
    }
}

/// What the items say.
@MainActor
enum GlanceText {
    /// "12m", "2h", "2h10", "1d"
    static func short(_ seconds: TimeInterval) -> String {
        switch DurationParts.of(seconds, roundUp: true) {
        case .underMinute:
            return String(format: String(localized: "glance.duration.minutes %lld"), Int64(1))
        case .minutes(let m):
            return String(format: String(localized: "glance.duration.minutes %lld"), Int64(m))
        case .hours(let h, let m):
            return m == 0
                ? String(format: String(localized: "glance.duration.hours %lld"), Int64(h))
                : String(format: String(localized: "glance.duration.hours-minutes %lld %@"), Int64(h),
                         String(format: "%02d", m))
        case .days(let d, _):
            return String(format: String(localized: "glance.duration.days %lld"), Int64(d))
        }
    }

    /// "14:00 · 12m", the time as the Mac writes it.
    static func meeting(start: Date, minutes: Int) -> String {
        let left = minutes > 0 ? short(TimeInterval(minutes * 60)) : String(localized: "day.meeting.now")
        return "\(start.formatted(date: .omitted, time: .shortened)) · \(left)"
    }

    /// The line under an item. Never an event's title or a message.
    static func detail(_ item: GlanceItem, now: Date) -> String {
        switch item.content {
        case .ci(let checks, let reviews):
            var parts: [String] = []
            switch checks {
            case .passing?: parts.append(String(localized: "glance.ci.passing"))
            case .failing?: parts.append(String(localized: "glance.ci.failing"))
            case .running?: parts.append(String(localized: "glance.ci.running"))
            case .noChecks?, nil: break
            }
            if reviews > 0 {
                parts.append(String(format: String(localized: "glance.reviews %lld"), Int64(reviews)))
            }
            return parts.joined(separator: " · ")
        case .jira(let key, _):
            return "Jira · \(key)"
        case .meeting(_, let minutes):
            guard minutes > 0 else { return String(localized: "day.meeting.now") }
            return String(format: String(localized: "day.meeting.in %@"),
                          DurationParts.of(TimeInterval(minutes * 60)).text)
        case .usage(let fraction, let resetsAt):
            return String(format: String(localized: "glance.usage %lld %@"), Int64((fraction * 100).rounded()),
                          short(resetsAt.timeIntervalSince(now)))
        case .grokBot(let status):
            switch status {
            case .approval: return String(localized: "glance.grok.approval")
            case .question: return String(localized: "glance.grok.question")
            case .message:  return String(localized: "glance.grok.message")
            }
        case .slack(let badge):
            return "Slack · \(badge.text ?? "")"
        }
    }
}

/// A small turning arc while checks run. Core Animation turns it outside the app: no timer
/// and no redraw here.
private struct GlanceSpinner: NSViewRepresentable {
    let spinning: Bool

    func makeNSView(context: Context) -> GlanceSpinnerView { GlanceSpinnerView() }

    func updateNSView(_ view: GlanceSpinnerView, context: Context) { view.spinning = spinning }
}

private final class GlanceSpinnerView: NSView {
    private static let key = "spin"
    private let arc = CAShapeLayer()

    var spinning = false { didSet { apply() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.strokeColor = NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1).cgColor
        arc.lineWidth = 1.8
        arc.lineCap = .round
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the item's button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        arc.frame = bounds
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY),
                    radius: max(0, min(bounds.width, bounds.height) / 2 - 1),
                    startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
        arc.path = path
        apply()
    }

    // A layer taken off the screen loses its animations.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard spinning, window != nil else {
            arc.removeAnimation(forKey: Self.key)
            return
        }
        guard arc.animation(forKey: Self.key) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1.1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: Self.key)
    }
}
#endif
