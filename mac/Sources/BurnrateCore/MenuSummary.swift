// What the menu bar shows: the most used limit, or whatever is running low.
import Foundation

public struct Headline: Codable, Equatable, Sendable {
    public var text: String
    public var level: Level
}

/// One limit at its critical level, for the "running low" banner.
public struct LowItem: Equatable, Sendable {
    public var source: String
    public var title: String
    public var label: String
    public var value: String
    public var resetAt: Int64?
    public var link: String
    public var isBalance: Bool
}

public enum MenuSummary {
    /// Short source names for the menu bar, where every character counts.
    static let short = ["claude": "CL", "codex": "GPT", "openrouter": "OR", "replicate": "REP", "higgsfield": "HF"]

    /// Section titles: Codex is paid for as the ChatGPT plan.
    public static func title(_ s: Source) -> String {
        (s.name == "codex" ? "ChatGPT" : s.title).uppercased()
    }

    /// "5H WINDOW" → "5H", "7D FABLE" → "FABLE".
    public static func shortLabel(_ label: String) -> String {
        if label.hasSuffix(" WINDOW") { return String(label.dropLast(7)) }
        if label.hasPrefix("7D "), label.count > 3 { return String(label.dropFirst(3)) }
        return label
    }

    /// The balance a source leads with: money left or credits, nil for limit cards.
    public static func balance(_ s: Source) -> Meter? {
        guard !s.gauges.contains(where: { $0.kind == "percent" }) else { return nil }
        return s.gauges.first { $0.dir == "left" } ?? s.gauges.first { $0.kind == "credits" }
    }

    /// Worst level wins; on a tie the highest used percent. A normal state
    /// shows just the percent, an alert names its source.
    public static func headline(_ sources: [Source]) -> Headline? {
        var best: (rank: Int, used: Double, h: Headline)?
        for s in sources {
            var items: [(Meter, Bool)] = s.gauges.filter { $0.kind == "percent" }.map { ($0, true) }
            if let b = balance(s) { items.append((b, false)) }
            for (g, isPercent) in items {
                let level = Format.level(g, g.value)
                let rank = level == .crit ? 2 : level == .warn ? 1 : 0
                let used = isPercent ? g.value : -1
                guard best == nil || rank > best!.rank || (rank == best!.rank && used > best!.used) else { continue }
                var text = Format.value(kind: g.kind, g.value)
                if rank > 0 { text = (short[s.name] ?? s.name.uppercased()) + " " + text }
                if !isPercent && rank == 0 { continue }  // balances only speak up when low
                best = (rank, used, Headline(text: text, level: level))
            }
        }
        return best?.h
    }

    /// Every limit or balance at the critical level, in card order.
    public static func lows(_ sources: [Source]) -> [LowItem] {
        sources.flatMap { s -> [LowItem] in
            var items = s.gauges.filter { $0.kind == "percent" }.map { ($0, false) }
            if let b = balance(s) { items.append((b, true)) }
            return items.filter { Format.level($0.0, $0.0.value) == .crit }.map { g, isBalance in
                LowItem(
                    source: s.name, title: s.name == "codex" ? "Codex" : s.title, label: g.label,
                    value: Format.value(kind: g.kind, g.value), resetAt: g.resetAt, link: s.link, isBalance: isBalance)
            }
        }
    }
}
