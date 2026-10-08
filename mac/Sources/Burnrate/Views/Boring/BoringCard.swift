import BurnrateCore
import SwiftUI

/// One source as an opaque rounded card. Rows share the tallest card's height:
/// gauges stay on top, sparkline and footer sit at the bottom.
struct BoringCard: View {
    let source: Source
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            VStack(alignment: .leading, spacing: 12) {
                ForEach(source.gauges) { g in BoringGauge(gauge: g, source: source) }
            }
            .opacity(dimmed)
            .saturation(source.status == .stale || source.status == .dead ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: source.status)
            Spacer(minLength: 0)
            if source.status != .link, let spark = source.spark, spark.count > 1 {
                BoringSparkline(points: spark)
                    .opacity(dimmed)
                    .help("Recent history")
            }
            if !source.message.isEmpty {
                Label {
                    MessageText(source: source)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(messageColor)
                .tint(messageColor)
                .lineLimit(2)
            }
            foot
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Boring.card, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.35 : 0.06),
                    lineWidth: contrast == .increased ? 1 : 0.5)
        }
    }

    private var head: some View {
        HStack(spacing: 8) {
            Image(systemName: Boring.symbol(source.name))
                .foregroundStyle(.tint)
                .imageScale(.large)
            Text(source.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Ticking { now in
                if let (text, color) = status(now: now) {
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(text).foregroundStyle(color)
                    }
                } else {
                    Text(Format.factsLine(source.facts))
                        .foregroundStyle(.secondary)
                        .help(source.facts.map { Format.sentence($0.label) + ": " + $0.value }.joined(separator: "\n"))
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    /// Header status when something is off; nil leaves room for the plan facts.
    private func status(now: Int64) -> (String, Color)? {
        let age = source.lastOkAt > 0 ? Format.ago(ms: now - source.lastOkAt) : ""
        switch source.status {
        case .stale: return ("Stale · " + age, .orange)
        case .error: return ("Error", .red)
        case .dead: return ("Not responding", .red)
        default: return nil
        }
    }

    private var foot: some View {
        HStack(spacing: 8) {
            if source.status != .link {
                Ticking { now in
                    Text(footText(now: now))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = URL(string: source.link), !source.link.isEmpty {
                LinkLabel(url: url) {
                    Text("Open ↗")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func footText(now: Int64) -> String {
        let cd = store.cooldownUntil(source.name)
        if cd > now { return "Wait \((cd - now + 999) / 1000) s" }
        if source.status == .fetching { return "Updating…" }
        let next = source.nextRefreshAt > 0 ? "next in " + Format.span(ms: source.nextRefreshAt - now) : ""
        guard source.lastOkAt > 0 else { return Format.sentence(next) }
        let updated = "Updated " + Format.ago(ms: now - source.lastOkAt)
        return next.isEmpty ? updated : updated + " · " + next
    }

    private var dimmed: Double {
        switch source.status {
        case .stale, .dead: 0.55
        case .error: 0.75
        default: 1
        }
    }

    private var messageColor: Color {
        switch source.status {
        case .error, .dead: .red
        case .link: .secondary
        default: .orange
        }
    }
}

/// Label and value on top, the bar, then reset time and forecast underneath.
struct BoringGauge: View {
    let gauge: Meter
    let source: Source
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.showPace) private var showPace = true

    var body: some View {
        let level = Format.level(gauge, gauge.value)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.niceLabel(gauge.label))
                    .lineLimit(1)
                Spacer(minLength: 8)
                TweenNumber(value: gauge.value, kind: gauge.kind, suffix: gauge.kind == "credits" ? " cr" : "")
                    .tween(gauge.value, reduce: reduceMotion)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Boring.text(level, hasBar: gauge.max != nil))
            }
            if let max = gauge.max {
                CapsuleBar(fill: max == 0 ? 0 : gauge.value / max, color: Boring.fill(level), elapsed: gauge.elapsed)
                    .padding(.top, 6)
            }
            caption
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var caption: some View {
        let reset = (gauge.resetAt ?? 0) > 0 ? gauge.resetAt : nil
        let usd = gauge.kind == "credits" ? source.facts.first { $0.label == "≈ USD" }?.value : nil
        let pace = showPace && gauge.pace != nil
        if reset != nil || pace || usd != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let reset {
                    Ticking { now in Text("Resets in " + Format.span(ms: reset - now)) }
                } else if let usd {
                    Text("≈ " + usd)
                }
                Spacer(minLength: 8)
                if pace { BoringPace(gauge: gauge) }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 4)
        }
    }
}

/// History as a quiet line with a faint fill.
struct BoringSparkline: View {
    let points: [Double]
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 20

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1, let lo = points.min(), let hi = points.max() else { return }
            let span = hi - lo == 0 ? 1 : hi - lo
            var line = Path()
            for (i, v) in points.enumerated() {
                let pt = CGPoint(
                    x: size.width * Double(i) / Double(points.count - 1),
                    y: size.height * (0.92 - (v - lo) / span * 0.8))
                i == 0 ? line.move(to: pt) : line.addLine(to: pt)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(.accentColor.opacity(0.08)))
            ctx.stroke(line, with: .color(.accentColor.opacity(0.5)), lineWidth: 1)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
