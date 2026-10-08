import AppKit
import BurnrateCore
import SwiftUI

/// The drop-down of the menu bar item: limits and balances, nothing else.
struct MenuPanel: View {
    @AppStorage(Look.key) private var look: Look = .initial

    var body: some View {
        switch look {
        case .boring: BoringPanel()
        case .cyberpunk: CyberPanel()
        }
    }
}

/// The Cyberpunk panel: black, mono, LED bars.
struct CyberPanel: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(store.ordered.filter(isLimits)) { s in LimitSection(source: s) }
                let balances = store.ordered.compactMap { s in MenuSummary.balance(s).map { (s, $0) } }
                if !balances.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label11(text: "BALANCE", size: 10, em: 0.14)
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            ForEach(balances, id: \.0.name) { s, g in BalanceRow(source: s, gauge: g) }
                        }
                    }
                }
            }
            .padding(16)
            .redacted(reason: store.isPlaceholder ? .placeholder : [])
            Theme.line.frame(height: 1)
            MenuFooter()
        }
        .frame(width: 360)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private func isLimits(_ s: Source) -> Bool { s.gauges.contains { $0.kind == "percent" } }
}

private struct LimitSection: View {
    let source: Source
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.showPace) private var showPace = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label11(text: MenuSummary.title(source), size: 10, em: 0.14)
                Spacer(minLength: 8)
                // what the last 30 days of usage would cost at API prices
                if let api = store.total?.api, let usd = api.usd(for: source.name) {
                    Label11(text: api.label + Format.usd(usd), size: 10, em: 0.08)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(source.gauges.filter { $0.kind == "percent" }) { g in
                    let level = Format.level(g, g.value)
                    GridRow {
                        Label11(text: MenuSummary.shortLabel(g.label), size: 12, em: 0.08)
                            .frame(width: 52, alignment: .leading)
                        BarView(
                            fill: (g.max ?? 100) == 0 ? 0 : g.value / (g.max ?? 100), color: Theme.fill(level),
                            height: 9, cell: 5, gap: 2
                        )
                        .frame(maxWidth: .infinity)
                        TweenNumber(value: g.value, kind: g.kind)
                            .tween(g.value, reduce: reduceMotion)
                            .font(Theme.mono(12, bold: true))
                            .foregroundStyle(Theme.color(level))
                            .frame(width: 44, alignment: .trailing)
                        Group {
                            // an empty cell still holds the column, or the reset slides left
                            if showPace && g.pace != nil { PaceMark(gauge: g, size: 11, showsPercent: false) } else { Color.clear.frame(height: 1) }
                        }
                        .frame(width: 26, alignment: .leading)
                        Ticking { now in
                            Label11(text: (g.resetAt ?? 0) > 0 ? Format.left(ms: g.resetAt! - now) : "", size: 11, em: 0)
                        }
                        .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .opacity(source.status == .stale || source.status == .dead ? 0.45 : 1)
    }
}

private struct BalanceRow: View {
    let source: Source
    let gauge: Meter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GridRow {
            Label11(text: source.title, size: 12, em: 0.08)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TweenNumber(value: gauge.value, kind: gauge.kind)
                    .tween(gauge.value, reduce: reduceMotion)
                    .font(Theme.mono(14, bold: true))
                    .foregroundStyle(Theme.color(Format.level(gauge, gauge.value)))
                if gauge.kind == "credits" {
                    Text("CR").font(Theme.mono(14, bold: true))
                    if let usd = source.facts.first(where: { $0.label == "≈ USD" }) {
                        Label11(text: "≈ " + usd.value, size: 11, em: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .opacity(source.status == .stale || source.status == .dead ? 0.45 : 1)
    }
}

private struct MenuFooter: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let age = ctx.date.timeIntervalSince(store.updatedAt)
                Label11(text: Format.age(ms: Int64(age * 1000)), size: 10)
                    .help("Since the last update")
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
            }
            TextButton(title: "OPEN WINDOW ⌘O") {
                dismiss()  // the window takes over: close the panel
                AppDelegate.showWindow(openWindow)
            }
            .help("Opens the window and closes this panel")
            Spacer(minLength: 0)
            TextButton(title: "SETTINGS", color: Theme.muted) {
                dismiss()
                AppDelegate.showSettings(openSettings)
            }
            .help("Settings (⌘,)")
            TextButton(title: "QUIT", color: Theme.muted) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct TextButton: View {
    let title: String
    var color = Theme.text
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label11(text: title, color: hover ? Theme.accent : color, em: 0.1, bold: true)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
    }
}

/// Menu bar item: a gauge symbol (Boring) or three bars (Cyberpunk) plus the
/// headline. Template (follows the menu bar's light or dark look) while all
/// is well, coloured once something is low.
struct MenuBarLabel: View {
    let store: Store
    @AppStorage(Look.key) private var look: Look = .initial

    var body: some View {
        Image(nsImage: MenuIcon.render(store.isPlaceholder ? nil : MenuSummary.headline(store.ordered), look: look))
    }
}

@MainActor
enum MenuIcon {
    static func render(_ h: Headline?, look: Look) -> NSImage {
        let level = h?.level ?? .normal
        let color: Color =
            switch (look, level) {
            case (_, .normal): .black
            case (.boring, .warn): Color(nsColor: .systemOrange)
            case (.boring, .crit): Color(nsColor: .systemRed)
            case (.cyberpunk, .warn): Theme.warn
            case (.cyberpunk, .crit): Theme.crit
            }
        let content = HStack(spacing: 4) {
            if look == .boring {
                Image(systemName: gaugeSymbol(h))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
            } else {
                BarsGlyph(color: color, alert: level != .normal)
                    .frame(width: 16, height: 14)
            }
            if let h {
                Text(h.text)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 14))
        image.isTemplate = level == .normal
        return image
    }

    /// The needle points at the headline's percent; balances and no data rest at zero.
    static func gaugeSymbol(_ h: Headline?) -> String {
        guard let h, let pct = h.text.split(separator: " ").last.flatMap({ Double($0.dropLast()) }),
            h.text.hasSuffix("%")
        else { return "gauge.with.dots.needle.0percent" }
        let step = [0, 33, 50, 67, 100].min { abs(Double($0) - pct) < abs(Double($1) - pct) } ?? 0
        return "gauge.with.dots.needle.\(step)percent"
    }
}

private struct BarsGlyph: View {
    let color: Color
    let alert: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = size.height / 14
            let bars = [
                CGRect(x: 1, y: 7, width: 3, height: 6), CGRect(x: 6.5, y: 4, width: 3, height: 9),
                CGRect(x: 12, y: 1, width: 3, height: 12),
            ]
            for (i, r) in bars.enumerated() {
                let rect = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
                if alert && i == 0 { ctx.fill(Path(rect), with: .color(color)) }
                ctx.stroke(Path(rect), with: .color(color), lineWidth: 1.6 * s)
            }
        }
    }
}
