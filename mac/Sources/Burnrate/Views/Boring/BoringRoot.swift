import BurnrateCore
import SwiftUI

/// The Boring window: alert banner, month summary, then the cards. Content
/// scrolls under the glass toolbar.
struct BoringRoot: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            BoringContent()
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Boring.canvas)
    }
}

/// Everything inside the scroll view; the debug snapshot renders it directly.
struct BoringContent: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            BoringBackendBanner()
            BoringLowBanner()
            if let t = store.total, !t.items.isEmpty { SpendSummary(total: t) }
            CardGrid(spacing: 12, minWidth: 300) {
                ForEach(store.ordered) { s in BoringCard(source: s) }
            }
            .redacted(reason: store.isPlaceholder ? .placeholder : [])
        }
        .padding(16)
    }

}

/// "2 limits running low": names each one and offers the top-up link.
struct BoringLowBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        let lows = store.isPlaceholder ? [] : MenuSummary.lows(store.ordered)
        if !lows.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.white, .red)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lows.count == 1 ? "1 limit running low" : "\(lows.count) limits running low")
                        .font(.headline)
                    Ticking { now in
                        Text(lows.map { describe($0, now: now) }.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let top = lows.first(where: { $0.isBalance && !$0.link.isEmpty }), let url = URL(string: top.link) {
                    LinkLabel(url: url) {
                        Text("Top Up \(top.title)…").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func describe(_ l: LowItem, now: Int64) -> String {
        if l.isBalance { return "\(l.title) balance \(l.value)" }
        var s = "\(l.title) \(Format.niceLabel(l.label)) at \(l.value)"
        if let r = l.resetAt, r > 0 { s += ", resets in " + Format.span(ms: r - now) }
        return s
    }
}

/// Month spend with its breakdown and the API-price estimate.
private struct SpendSummary: View {
    let total: MonthTotal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showAPI = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                headline; Divider(); breakdown; Divider(); api
            }
            VStack(alignment: .leading, spacing: 12) {
                headline; breakdown; api
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Boring.card, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.35 : 0.06),
                    lineWidth: contrast == .increased ? 1 : 0.5)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Boring.monthName(total.month)) spend")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TweenNumber(value: total.total, kind: "money")
                    .tween(total.total, reduce: reduceMotion)
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                if total.estimate {
                    Text("estimate").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
    }

    private var breakdown: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(total.items) { item in
                GridRow {
                    Text(itemTitle(item)).foregroundStyle(.secondary)
                    Text((item.estimate == true ? "≈ " : "") + Format.usd(item.usd))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var api: some View {
        if let api = total.api {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("At API prices, \(api.days ?? 30) days")
                    Button {
                        showAPI.toggle()
                    } label: {
                        Image(systemName: "info.circle").imageScale(.small).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("What is this?")
                    .accessibilityLabel("About the API price estimate")
                    .popover(isPresented: $showAPI, arrowEdge: .bottom) { APIExplainer(api: api) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text("≈ " + Format.usd(api.usd))
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            .fixedSize()
        }
    }

    private func itemTitle(_ i: MonthItem) -> String {
        if i.kind == "subscription" { return i.title }
        if let since = i.since, since > 0 {
            let d = Date(timeIntervalSince1970: Double(since) / 1000)
            return "\(i.title) usage, since \(d.formatted(.dateTime.day().month(.abbreviated)))"
        }
        return "\(i.title) usage"
    }
}

/// Popover behind the ⓘ: what the API estimate counts, split per tool.
private struct APIExplainer: View {
    let api: APICost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("≈ \(Format.usd(api.usd)) at API prices")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("Claude Code and Codex tokens of the last \(api.days ?? 30) days on this Mac, priced per token at OpenRouter's list prices, cache included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !api.items.isEmpty {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(api.items) { item in
                        GridRow {
                            Text(item.title)
                            Text(Format.usd(item.usd)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.callout)
            }
            Text("Chats on claude.ai or chatgpt.com and other computers are not counted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

/// The engine cannot start (a broken config.json): shown above everything else.
struct BoringBackendBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let why = model.failure {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Cannot start: " + why).lineLimit(2)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }
}
