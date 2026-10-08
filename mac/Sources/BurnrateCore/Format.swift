// Text formatting shared by the window, the menu bar panel and the widget.
import Foundation

public enum Level: String, Codable, Sendable { case normal, warn, crit }

public enum Format {
    private static func fixed(_ v: Double, _ digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(digits)f", v)
    }

    public static func usd(_ v: Double) -> String { "$" + fixed(v, 2) }

    public static func value(kind: String, _ v: Double) -> String {
        switch kind {
        case "percent": return "\(Int(v.rounded()))%"
        case "money": return usd(v)
        default: return fixed(v, 1)
        }
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Countdown: "2D 04H", "3H 05M", "04M 09S", "NOW".
    public static func left(ms: Int64) -> String {
        if ms <= 0 { return "NOW" }
        let t = Int(ms / 1000)
        let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60, s = t % 60
        if d > 0 { return "\(d)D \(pad(h))H" }
        if h > 0 { return "\(h)H \(pad(m))M" }
        return "\(pad(m))M \(pad(s))S"
    }

    /// Age since the last good fetch: "09S", "12M", "5H", "3D".
    public static func age(ms: Int64) -> String {
        let t = Int(max(0, ms / 1000))
        if t < 60 { return pad(t) + "S" }
        if t < 3600 { return pad(t / 60) + "M" }
        if t < 172_800 { return "\(t / 3600)H" }
        return "\(t / 86400)D"
    }

    public static func status(_ s: Status) -> String {
        switch s {
        case .ok: "FRESH"
        case .stale: "STALE"
        case .error: "ERR"
        case .dead: "DEAD"
        case .fetching: "SYNC"
        case .link: "LINK"
        case .unknown: "?"
        }
    }

    /// Colour level of a gauge value: provider severity, then absolute
    /// thresholds for money left, then the share of max.
    public static func level(_ g: Meter, _ v: Double) -> Level {
        if g.severity == "crit" { return .crit }
        if g.severity == "warn" { return .warn }
        if let c = g.critBelow, v < c { return .crit }
        if let w = g.warnBelow, v < w { return .warn }
        guard let max = g.max, max != 0 else { return .normal }
        let x = v / max * 100
        let warn = g.warnAt ?? 75, crit = g.critAt ?? 90
        if g.dir == "used" { return x >= crit ? .crit : x >= warn ? .warn : .normal }
        return x <= 100 - crit ? .crit : x <= 100 - warn ? .warn : .normal
    }

    private static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// "2026-10" → "OCT 2026".
    public static func month(_ ym: String) -> String {
        let p = ym.split(separator: "-")
        guard p.count == 2, let m = Int(p[1]), (1...12).contains(m) else { return ym }
        return "\(months[m - 1]) \(p[0])"
    }

    public static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        return "\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0)):\(pad(c.second ?? 0))"
    }

    /// Spoken summary of the pace forecast (VoiceOver); nil without a forecast.
    public static func paceTip(_ g: Meter) -> String? {
        guard let pace = g.pace, let elapsed = g.elapsed else { return nil }
        let r = { (v: Double) in Int(v.rounded()) }
        let verdict =
            switch g.paceLevel {
            case "under": "room to burn more"
            case "over": "slow down"
            default: "on track"
            }
        return "\(r(pace))% by reset at this pace, \(verdict). \(r(g.value))% used, \(r(elapsed))% of the window gone."
    }

    // MARK: Boring look: sentence case and plain-English times

    /// "5H WINDOW" → "5-hour", "7D FABLE" → "7-day · Fable", "SPENT TODAY" → "Spent today".
    public static func niceLabel(_ label: String) -> String {
        let words = label.split(separator: " ").map(String.init)
        guard let first = words.first else { return label }
        let windows = ["5H": "5-hour", "7D": "7-day", "24H": "24-hour", "30D": "30-day"]
        if let w = windows[first.uppercased()] {
            let rest = words.dropFirst().filter { $0.uppercased() != "WINDOW" }.map { $0.lowercased().capitalized }
            return ([w] + rest).joined(separator: " · ")
        }
        return sentence(label)
    }

    /// "SPENT MONTH" → "Spent month", "MAX" → "Max".
    public static func sentence(_ s: String) -> String {
        let low = s.lowercased()
        return low.prefix(1).uppercased() + low.dropFirst()
    }

    /// Countdown in words: "3 h 05 min", "22 min", "3 d 02 h", "40 s", "now".
    public static func span(ms: Int64) -> String {
        if ms <= 0 { return "now" }
        let t = Int(ms / 1000)
        let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60
        if d > 0 { return "\(d) d \(pad(h)) h" }
        if h > 0 { return "\(h) h \(pad(m)) min" }
        if m > 0 { return "\(m) min" }
        return "\(t) s"
    }

    /// Age in words: "9 s ago", "2 min ago", "5 h ago", "3 d ago".
    public static func ago(ms: Int64) -> String {
        let t = Int(max(0, ms / 1000))
        if t < 60 { return "\(t) s ago" }
        if t < 3600 { return "\(t / 60) min ago" }
        if t < 172_800 { return "\(t / 3600) h ago" }
        return "\(t / 86400) d ago"
    }

    /// "Max 20× · Off": fact values in sentence case, for the card header.
    public static func factsLine(_ facts: [Fact]) -> String {
        facts.map { sentence($0.value) }.joined(separator: " · ")
    }
}
