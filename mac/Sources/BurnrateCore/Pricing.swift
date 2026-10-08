// Default prices. A plan the provider reports is priced from this table;
// config.json `providers.<name>.monthly_usd` overrides it.
import Foundation

public enum Pricing {
    /// USD per month by the plan id providers report (checked 2026-10).
    /// ChatGPT Pro also exists at $100; the API says just "pro", so set
    /// monthly_usd in config.json when that is the plan.
    public static let plans: [String: Double] = [
        "claude_pro": 20, "claude_max_5x": 100, "claude_max_20x": 200, "chatgpt_plus": 20, "chatgpt_pro": 200,
    ]

    /// Price of one Higgsfield credit on the Pro plan.
    public static let higgsfieldUSDPerCredit = 0.048
}
