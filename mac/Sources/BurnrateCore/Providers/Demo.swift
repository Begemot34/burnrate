// Demo mimics a real card with drifting values and occasional failures,
// so every UI state can be seen without touching real accounts.
import Foundation

public struct Demo: Provider {
    public let name: String
    public let title: String
    private let balance: Bool
    private let plan: String
    private let unitUSD: Double
    private let facts: [Fact]
    private let gauges: Locked<[Meter]>

    public var link: String { "https://example.com/" + name }
    public var note: String { "" }

    init(
        _ name: String, _ title: String, _ gauges: [Meter], facts: [Fact] = [], balance: Bool = false,
        plan: String = "", unitUSD: Double = 0
    ) {
        self.name = name
        self.title = title
        self.gauges = Locked(gauges)
        self.facts = facts
        self.balance = balance
        self.plan = plan
        self.unitUSD = unitUSD
    }

    public static func all(now: Date = Date()) -> [any Provider] {
        func at(_ d: TimeInterval) -> Int64 { ms(now.addingTimeInterval(d)) }
        return [
            Demo(
                "claude", "Claude Code",
                [
                    pct("h5", "5H WINDOW", 42, at(2 * 3600 + 13 * 60), hour5),
                    pct("d7", "7D WINDOW", 61, at(77 * 3600), week),
                    pct("d7_fable", "7D FABLE", 18, at(77 * 3600), week),
                ], facts: [Fact("PLAN", "MAX"), Fact("EXTRA", "OFF")], plan: "claude_max_20x"),
            Demo(
                "codex", "Codex",
                [
                    pct("h5", "5H WINDOW", 88, at(47 * 60), hour5),
                    pct("d7", "7D WINDOW", 40, at(95 * 3600), week),
                    pct("d7_spark", "7D SPARK", 3, at(160 * 3600), week),
                ], facts: [Fact("PLAN", "PLUS"), Fact("GPT-6-ASTRA", "OK")], plan: "chatgpt_plus"),
            Demo(
                "openrouter", "OpenRouter",
                [
                    moneyLeft("left", "CREDITS LEFT", 18.42),
                    Meter(key: "day", label: "SPENT TODAY", kind: "money", value: 1.27),
                    Meter(key: "month", label: "SPENT MONTH", kind: "money", value: 31.58),
                ], balance: true),
            Demo(
                "replicate", "Replicate",
                [
                    moneyLeft("left", "CREDITS LEFT", 7.2),
                    Meter(key: "month", label: "SPENT MONTH", kind: "money", value: 12.8),
                ], facts: [Fact("USER", "DEMO")], balance: true),
            Demo(
                "higgsfield", "Higgsfield",
                [
                    Meter(key: "credits", label: "CREDITS", kind: "credits", value: 410.5)
                ], facts: [Fact("PLAN", "PRO")], balance: true, unitUSD: Pricing.higgsfieldUSDPerCredit),
        ]
    }

    /// The API-price estimate shown in demo mode.
    public static let apiCost = APICost(
        days: 30, usd: 1712.38,
        items: [
            APIItem(name: "claude", title: "Claude Code", usd: 1654.10, tokens: 2_900_000_000),
            APIItem(name: "codex", title: "ChatGPT", usd: 58.28, tokens: 54_600_000),
        ])

    public func fetch() async throws -> Snapshot {
        try await Task.sleep(for: .milliseconds(200 + Int.random(in: 0..<600)))
        switch Int.random(in: 0..<20) {
        case 0: throw ProviderError.retryAfter(20)
        case 1: throw ProviderError.failed("demo: connection reset")
        case 2 where name == "replicate": throw ProviderError.auth("SESSIONID COOKIE EXPIRED — PASTE A NEW ONE")
        default: break
        }
        let balance = balance
        let gs = gauges.withLock { gs in
            for i in gs.indices {
                var g = gs[i]
                if g.kind == "percent" {
                    g.value = min(100, max(0, g.value + Double.random(in: 0..<1) * 6 - 1.5))
                    if g.value >= 100 { g.value = 5 }
                } else if g.dir == "left" || (balance && g.max == nil) {
                    g.value = max(0, g.value - Double.random(in: 0..<1) * (g.value * 0.03 + 0.5))
                    if g.value < 2 { g.value += 25 }  // fake top-up, so warn/crit colours cycle
                } else {
                    g.value += Double.random(in: 0..<1) * 0.8
                }
                gs[i] = g
            }
            return gs
        }
        var s = Snapshot()
        (s.gauges, s.facts, s.balance, s.plan, s.unitUSD) = (gs, facts, balance, plan, unitUSD)
        s.series = gs[0].value
        s.monthUSD = gs.first { $0.key == "month" }?.value
        return s
    }
}
