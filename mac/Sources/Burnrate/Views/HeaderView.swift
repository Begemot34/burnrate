import BurnrateCore
import SwiftUI

struct HeaderView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text("BURNRATE\(Text("//").foregroundStyle(Theme.accent))LIMITS")
                .font(Theme.display(34))
                .tracking(-0.68)
                .lineLimit(1)
                .fixedSize()
            if let t = store.total, !t.items.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Label11(text: Format.month(t.month), em: 0.14)
                    TweenNumber(value: t.total, kind: "money", prefix: t.estimate ? "≈" : "")
                        .tween(t.total, reduce: reduceMotion)
                        .font(Theme.mono(22, bold: true))
                        .foregroundStyle(Theme.accent)
                    if let api = t.api {
                        Label11(text: api.label + Format.usd(api.usd), size: 13, em: 0.1)
                            .help("Claude Code and Codex tokens of the last 30 days on this Mac, at API list prices")
                    }
                }
                .fixedSize()
            }
            if store.demo {
                Label11(text: "DEMO DATA — NOT YOUR ACCOUNTS", em: 0.14)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            Ticking { now in
                Text(Format.clock(Date(timeIntervalSince1970: Double(now) / 1000)))
                    .font(Theme.mono(22, bold: true))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)  // the transparent toolbar above holds the window buttons and the Look switch
        .padding(.bottom, 20)
    }
}

/// "2 LIMITS LOW · CODEX 5H 94% · RESET 22M · …": shown while anything is critical.
struct CyberLowBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        let lows = store.isPlaceholder ? [] : MenuSummary.lows(store.ordered)
        if !lows.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Ticking { now in
                        Label11(
                            text: ([lows.count == 1 ? "1 LIMIT LOW" : "\(lows.count) LIMITS LOW"]
                                + lows.map { describe($0, now: now) }).joined(separator: " · "),
                            color: Theme.crit, bold: true
                        )
                        .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if let top = lows.first(where: { $0.isBalance && !$0.link.isEmpty }), let url = URL(string: top.link) {
                        LinkLabel(url: url) {
                            Label11(text: "TOP UP \(top.title) ↗", color: Theme.text, em: 0.1, bold: true)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                Theme.line.frame(height: 1)
            }
        }
    }

    private func describe(_ l: LowItem, now: Int64) -> String {
        if l.isBalance { return "\(l.title) \(l.value)" }
        var s = "\(l.title) \(MenuSummary.shortLabel(l.label)) \(l.value)"
        if let r = l.resetAt, r > 0 { s += " · RESET " + Format.left(ms: r - now) }
        return s
    }
}

/// Shown only when the engine cannot start (a broken config.json).
struct BackendBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let why = model.failure {
            VStack(spacing: 0) {
                Label11(text: "CANNOT START: " + why, color: Theme.crit, bold: true)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                Theme.line.frame(height: 1)
            }
        }
    }
}
