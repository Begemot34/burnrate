import BurnrateCore
import SwiftUI

struct CardView: View {
    let source: Source
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            head
            VStack(alignment: .leading, spacing: 12) {
                ForEach(source.gauges) { g in GaugeRow(gauge: g) }
            }
            .opacity(dimmed)
            .saturation(source.status == .stale || source.status == .dead ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: source.status)
            // the row shares the tallest card's height: the gap goes here, the rest sits at the bottom
            Spacer(minLength: 0)
                .padding(.top, -16)
            if source.status != .link {
                SparklineView(points: source.spark ?? [])
            }
            facts
            if !source.message.isEmpty {
                MessageText(source: source, uppercase: true)
                    .font(Theme.mono(11))
                    .tracking(0.66)
                    .foregroundStyle(messageColor)
                    .tint(messageColor)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .lineLimit(3)
            }
            foot
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .overlay {
            if source.status == .dead || hasCrit { Rectangle().strokeBorder(Theme.crit, lineWidth: 1) }
        }
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(source.title.uppercased())
                .font(Theme.display(22))
                .tracking(-0.22)
                .lineLimit(1)
            Spacer(minLength: 0)
            ChipView(status: source.status)
            Ticking { now in
                Label11(text: source.status == .link ? "" : source.lastOkAt > 0 ? Format.age(ms: now - source.lastOkAt) : "--")
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
    }

    private var hasCrit: Bool {
        source.gauges.contains { $0.kind == "percent" && Format.level($0, $0.value) == .crit }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(source.facts) { f in
                GridRow {
                    Label11(text: f.label)
                    Text(f.value)
                        .font(Theme.mono(12))
                        .tracking(0.24)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
    }

    private var foot: some View {
        HStack(spacing: 12) {
            if source.status != .link {
                Ticking { now in
                    let cd = store.cooldownUntil(source.name)
                    Label11(text: nextText(now: now, cooldown: cd))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer(minLength: 0)
            }
            if let url = URL(string: source.link), !source.link.isEmpty {
                LinkLabel(url: url) {
                    Label11(text: "OPEN ↗", color: Theme.text, em: 0.1, bold: true)
                }
            }
        }
    }

    private func nextText(now: Int64, cooldown: Int64) -> String {
        if cooldown > now { return "WAIT \((cooldown - now + 999) / 1000)S" }
        if source.status == .fetching { return "SYNCING" }
        return source.nextRefreshAt > 0 ? "NEXT " + Format.left(ms: source.nextRefreshAt - now) : ""
    }

    private var dimmed: Double {
        switch source.status {
        case .stale, .dead: 0.45
        case .error: 0.75
        default: 1
        }
    }

    private var messageColor: Color {
        switch source.status {
        case .error, .dead: Theme.crit
        case .link: Theme.muted
        default: Theme.warn
        }
    }
}

struct GaugeRow: View {
    let gauge: Meter
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.showPace) private var showPace = true

    var body: some View {
        let level = Format.level(gauge, gauge.value)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Label11(text: gauge.label)
                    .lineLimit(1)
                    .fixedSize()
                if let reset = gauge.resetAt, reset > 0 {
                    Ticking { now in
                        let left = Label11(text: Format.left(ms: reset - now), color: Theme.text, bold: true).fixedSize()
                        // narrow cards drop the word, then the time; the value and forecast never truncate
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                Label11(text: "RESET").fixedSize(); left
                            }
                            left
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    .help(
                        "Resets in " + Format.span(ms: reset - store.nowMs())
                            + (gauge.elapsed.map { " · \(Int($0.rounded()))% of the window gone" } ?? ""))
                }
                Spacer(minLength: 0)
                TweenNumber(value: gauge.value, kind: gauge.kind)
                    .tween(gauge.value, reduce: reduceMotion)
                    .font(Theme.mono(26, bold: true))
                    .foregroundStyle(Theme.color(level))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: level)
                    .fixedSize()
                if showPace && gauge.pace != nil {
                    PaceMark(gauge: gauge, size: 15)
                        .fixedSize()
                }
            }
            if let max = gauge.max {
                BarView(fill: max == 0 ? 0 : gauge.value / max, color: Theme.fill(level), elapsed: gauge.elapsed)
            }
        }
    }
}

/// "→34%" and an under/on/over dot: the percent at reset if the pace holds.
/// The dot and ⓘ open a system popover (Liquid Glass on macOS 26) that explains the numbers.
struct PaceMark: View {
    let gauge: Meter
    var size: CGFloat = 15
    /// The menu panel shows only the dot and ⓘ; the percent lives in the popover.
    var showsPercent = true
    @State private var showTip = false

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.4) {
            if showsPercent {
                Text("→\(Int((gauge.pace ?? 0).rounded()))%")
                    .font(Theme.mono(size, bold: true))
                    .foregroundStyle(Theme.muted)
            }
            Button {
                showTip.toggle()
            } label: {
                HStack(spacing: size * 0.4) {
                    Circle()
                        .fill(Theme.pace(gauge.paceLevel))
                        .frame(width: size * 0.65, height: size * 0.65)
                    Image(systemName: "info.circle")
                        .font(.system(size: size * 0.8))
                        .foregroundStyle(showTip ? Theme.text : Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Forecast at reset")
            .accessibilityLabel(Format.paceTip(gauge) ?? "Forecast at reset")
            .popover(isPresented: $showTip, arrowEdge: .bottom) {
                PaceExplainer(gauge: gauge)
            }
        }
    }
}

/// Popover body: the forecast up top, how it was derived, and the colour key
/// drawn with the same dots as the row. Plain text styles so it reads on glass.
struct PaceExplainer: View {
    let gauge: Meter
    var color: (String?) -> Color = Theme.pace

    private static let key: [(level: String, range: String, meaning: String)] = [
        ("under", "< 80%", "room to burn more"),
        ("on", "80–110%", "on track"),
        ("over", "> 110%", "slow down, limit hits before reset"),
    ]

    var body: some View {
        let pct = { (v: Double?) in "\(Int((v ?? 0).rounded()))%" }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pct(gauge.pace)) by reset")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("\(pct(gauge.value)) used · \(pct(gauge.elapsed)) of the window gone, at the same pace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.key, id: \.level) { row in
                    let current = row.level == gauge.paceLevel
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(row.level))
                            .frame(width: 8, height: 8)
                        Text(row.range)
                            .font(.caption.monospacedDigit().weight(current ? .semibold : .regular))
                            .frame(width: 58, alignment: .leading)
                        Text(row.meaning)
                            .font(.caption.weight(current ? .semibold : .regular))
                    }
                    .foregroundStyle(current ? .primary : .secondary)
                }
            }
        }
        .fixedSize()
        .padding(14)
    }
}
