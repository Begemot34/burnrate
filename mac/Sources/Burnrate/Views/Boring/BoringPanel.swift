import AppKit
import BurnrateCore
import SwiftUI

/// The menu bar drop-down in the Boring look: no background of its own, the
/// system draws the Liquid Glass panel like Control Center's.
struct BoringPanel: View {
    @Environment(Store.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.ordered.filter(isLimits)) { s in BoringLimitSection(source: s) }
            let balances = store.ordered.compactMap { s in MenuSummary.balance(s).map { (s, $0) } }
            if !balances.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Balances").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(balances, id: \.0.name) { s, g in BoringBalanceRow(source: s, gauge: g) }
                    }
                    .platter(contrast)
                }
            }
            BoringPanelFooter()
        }
        .padding(12)
        .frame(width: 320)
        .redacted(reason: store.isPlaceholder ? .placeholder : [])
    }

    private func isLimits(_ s: Source) -> Bool { s.gauges.contains { $0.kind == "percent" } }
}

extension View {
    /// Inset rounded group inside the glass panel, concentric with its corners.
    func platter(_ contrast: ColorSchemeContrast, alert: Bool = false) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(contrast == .increased ? 1 : 0.6), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                if alert || contrast == .increased {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(alert ? Color.red : Color.primary.opacity(0.3), lineWidth: alert ? 1.5 : 1)
                }
            }
    }
}

private struct BoringLimitSection: View {
    let source: Source
    @Environment(Store.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Prefs.showPace) private var showPace = true

    var body: some View {
        let gauges = source.gauges.filter { $0.kind == "percent" }
        let hot = gauges.contains { Format.level($0, $0.value) == .crit }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Boring.symbol(source.name)).foregroundStyle(.tint)
                Text(source.name == "codex" ? "ChatGPT" : source.title).font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if let api = store.total?.api, let usd = api.usd(for: source.name) {
                    Text("API \(api.days ?? 30)d ≈ \(Format.usd(usd))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("What the last \(api.days ?? 30) days would cost at API prices")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(gauges) { g in
                    let level = Format.level(g, g.value)
                    GridRow {
                        Text(Boring.shortLabel(g.label))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        CapsuleBar(fill: (g.max ?? 100) == 0 ? 0 : g.value / (g.max ?? 100), color: Boring.fill(level))
                            .frame(maxWidth: .infinity)
                        TweenNumber(value: g.value, kind: g.kind)
                            .tween(g.value, reduce: reduceMotion)
                            .fontWeight(.semibold)
                            .foregroundStyle(Boring.text(level, hasBar: true))
                            .frame(width: 38, alignment: .trailing)
                        BoringPaceDot(gauge: g.paced(showPace))
                        Ticking { now in
                            Text((g.resetAt ?? 0) > 0 ? Format.left(ms: g.resetAt! - now).lowercased() : "")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .frame(width: 52, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout.monospacedDigit())
            .platter(contrast, alert: hot)
        }
        .opacity(source.status == .stale || source.status == .dead ? 0.55 : 1)
    }
}

private struct BoringBalanceRow: View {
    let source: Source
    let gauge: Meter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = Format.level(gauge, gauge.value)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(source.title)
            Spacer(minLength: 8)
            if let note {
                Text(note.text).font(.caption).foregroundStyle(note.color)
            }
            TweenNumber(value: gauge.value, kind: gauge.kind, suffix: gauge.kind == "credits" ? " cr" : "")
                .tween(gauge.value, reduce: reduceMotion)
                .fontWeight(.semibold)
                .foregroundStyle(Boring.text(level, hasBar: false))
        }
        .font(.callout.monospacedDigit())
        .opacity(source.status == .stale || source.status == .dead ? 0.55 : 1)
    }

    private var note: (text: String, color: Color)? {
        if source.status == .error { return ("error", .red) }
        if gauge.kind == "credits", let usd = source.facts.first(where: { $0.label == "≈ USD" }) {
            return ("≈ " + usd.value + (source.status == .stale ? ", stale" : ""), .secondary)
        }
        if let c = gauge.critBelow, gauge.value < c { return ("below " + Format.usd(c), .secondary) }
        return source.status == .stale ? ("stale", .secondary) : nil
    }
}

private struct BoringPanelFooter: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let age = ctx.date.timeIntervalSince(store.updatedAt)
                Text("Updated " + Format.ago(ms: Int64(age * 1000)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Open Burnrate") {
                dismiss()
                AppDelegate.showWindow(openWindow)
            }
            .buttonStyle(.glass)
            .help("Opens the window and closes this panel (⌘O)")
            Button {
                dismiss()
                AppDelegate.showSettings(openSettings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings (⌘,)")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Quit Burnrate")
        }
        .padding(.top, 2)
    }
}
