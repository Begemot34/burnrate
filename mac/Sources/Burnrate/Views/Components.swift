import BurnrateCore
import SwiftUI

/// Number that counts from the old value to the new one, like the web tween.
struct TweenNumber: View, Animatable {
    var value: Double
    let kind: String
    var prefix = ""
    var suffix = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(prefix + Format.value(kind: kind, value) + suffix)
            .contentTransition(.identity)
    }
}

extension View {
    /// Animates a TweenNumber when its target changes (0.6 s ease-out).
    func tween(_ value: Double, reduce: Bool) -> some View {
        animation(reduce ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: 0.6), value: value)
    }
}

/// LED-segment bar: the fill scales from the left, the mask cuts 7 pt cells.
struct BarView: View {
    let fill: Double
    let color: Color
    var height: CGFloat = 16
    var cell: CGFloat = 7
    var gap: CGFloat = 2
    /// Share of the window gone, in percent: a tick across the bar.
    var elapsed: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.track
            color
                .scaleEffect(x: max(0, min(1, fill)), y: 1, anchor: .leading)
                .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7), value: fill)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: color)
        }
        .frame(height: height)
        .mask(Segments(cell: cell, gap: gap))
        .overlay(alignment: .leading) {
            if let elapsed {
                GeometryReader { geo in
                    Theme.text
                        .frame(width: 2, height: height + 6)
                        .offset(x: geo.size.width * min(1, max(0, elapsed / 100)) - 1, y: -3)
                }
                .help("\(Int(elapsed.rounded()))% of the window gone")
            }
        }
    }
}

struct Segments: Shape {
    var cell: CGFloat = 7
    var gap: CGFloat = 2

    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX
        while x < r.maxX {
            p.addRect(CGRect(x: x, y: r.minY, width: min(cell, r.maxX - x), height: r.height))
            x += cell + gap
        }
        return p
    }
}

struct SparklineView: View {
    let points: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1, let lo = points.min(), let hi = points.max() else { return }
            let span = hi - lo == 0 ? 1 : hi - lo
            var p = Path()
            for (i, v) in points.enumerated() {
                let pt = CGPoint(
                    x: size.width * Double(i) / Double(points.count - 1),
                    y: size.height * (22 - (v - lo) / span * 20) / 24)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            ctx.stroke(p, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .frame(height: 28)
    }
}

struct ChipView: View {
    let status: Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(Format.status(status))
            .font(Theme.mono(11, bold: true))
            .tracking(1.32)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 52)
            .background { bg }
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status)
    }

    private var fg: Color {
        switch status {
        case .ok: .white
        case .error: .black
        case .stale: Theme.warn
        case .dead: .white
        case .fetching: Theme.accent
        case .link, .unknown: Theme.muted
        }
    }

    private var border: Color {
        switch status {
        case .ok, .fetching: Theme.accent
        case .stale: Theme.warn
        case .error, .dead: Theme.crit
        case .link, .unknown: Theme.muted
        }
    }

    @ViewBuilder private var bg: some View {
        switch status {
        case .ok: Theme.accent
        case .error: Theme.crit
        case .dead: Stripes()
        default: Color.clear
        }
    }
}

/// 45° crit/black stripes of the DEAD chip.
struct Stripes: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            var x = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + 4, y: 0))
                p.addLine(to: CGPoint(x: x + 4, y: size.height))
                ctx.fill(p, with: .color(Theme.crit))
                x += 8
            }
        }
    }
}

/// A tappable link made of plain views. Unlike `Link`, it is rendered by
/// `ImageRenderer`, so snapshots show it instead of a placeholder box.
struct LinkLabel<Content: View>: View {
    let url: URL
    @ViewBuilder let content: Content
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { openURL(url) }
            .pointerStyle(.link)
            .accessibilityAddTraits(.isLink)
            .accessibilityAction { openURL(url) }
    }
}
