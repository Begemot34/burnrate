// Claude reads the OAuth token Claude Code keeps in the macOS Keychain and asks
// the (undocumented) usage endpoint. The token is never refreshed here: Claude
// Code rotates it, we only re-read. The Keychain is read with /usr/bin/security,
// which is already in the item's access list, so no access prompt appears.
import Foundation

public struct Claude: Provider {
    var deps: Deps
    var baseURL = "https://api.anthropic.com"

    public init(deps: Deps) { self.deps = deps }

    public var name: String { "claude" }
    public var title: String { "Claude Code" }
    public var link: String { "https://claude.ai/settings/usage" }
    public var note: String { "" }

    struct Creds: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            var expiresAt: Int64?
            var subscriptionType: String?
            var rateLimitTier: String?
        }
        var claudeAiOauth: OAuth?
    }

    struct Window: Decodable {
        var utilization: LooseNumber?
        var resets_at: Epoch?
    }

    /// One entry of the newer `limits` list; weekly_scoped ones carry the model (e.g. Fable).
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                var id: String?
                var display_name: String?
            }
            var model: Model?
        }
        var kind: String?  // session | weekly_all | weekly_scoped
        var percent: LooseNumber?
        var severity: String?
        var resets_at: Epoch?
        var scope: Scope?
    }

    struct Money: Decodable {
        var amount_minor: LooseNumber?
        var currency: String?
        var exponent: LooseNumber?

        var text: String {
            let v = (amount_minor?.value ?? 0) / pow(10, exponent?.value ?? 0)
            let cur = currency ?? ""
            return cur.isEmpty || cur == "USD" ? money(v) : fixed(v, 2) + " " + cur
        }
    }

    struct Usage: Decodable {
        struct Breakdown: Decodable {
            struct Row: Decodable {
                var key: String?
                var display_name: String?
                var percent: LooseNumber?
            }
            var rows: [Row]?
        }
        struct Extra: Decodable {
            var is_enabled: Bool?
            var monthly_limit: LooseNumber?
            var used_credits: LooseNumber?
            var currency: String?
            var decimal_places: LooseNumber?
        }
        struct Spend: Decodable {
            var enabled: Bool?
            var used: Money?
            var limit: Money?
        }
        var five_hour: Window?
        var seven_day: Window?
        var seven_day_opus: Window?
        var seven_day_sonnet: Window?
        var limits: [Limit]?
        var seven_day_breakdown: Breakdown?
        var extra_usage: Extra?
        var spend: Spend?
    }

    public func fetch() async throws -> Snapshot {
        let raw: Data
        do {
            raw = try await deps.exec([:], "/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        } catch {
            throw ProviderError.auth("NO CLAUDE CODE LOGIN IN KEYCHAIN — RUN CLAUDE")
        }
        guard let oauth = (try? JSONDecoder().decode(Creds.self, from: raw))?.claudeAiOauth,
            let token = oauth.accessToken, !token.isEmpty
        else { throw ProviderError.auth("CANNOT READ CLAUDE CODE CREDENTIALS") }
        if let exp = oauth.expiresAt, exp > 0, exp < ms(deps.now()) {
            throw ProviderError.auth("TOKEN EXPIRED — START CLAUDE ONCE TO RENEW")
        }

        let req = HTTP.request(
            baseURL + "/api/oauth/usage",
            ["Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"])
        let u: Usage
        do {
            u = try await HTTP.getJSON(deps, req)
        } catch  where error.isCode(401) {
            throw ProviderError.auth("TOKEN REJECTED — START CLAUDE ONCE TO RENEW")
        }

        var s = Self.snapshot(u)
        if let t = oauth.subscriptionType, !t.isEmpty { s.facts.append(Fact("PLAN", t.uppercased())) }
        if var t = oauth.rateLimitTier, !t.isEmpty {
            if t.hasPrefix("default_claude_") { t.removeFirst("default_claude_".count) }
            s.facts.append(Fact("TIER", t.replacingOccurrences(of: "_", with: " ").uppercased()))
        }
        s.plan = Self.plan(oauth.subscriptionType ?? "", oauth.rateLimitTier ?? "")
        s.facts += Self.extraFacts(u)
        return s
    }

    static func snapshot(_ u: Usage) -> Snapshot {
        var s = Snapshot()
        for l in u.limits ?? [] {
            var key = "", label = "", window = week
            switch l.kind {
            case "session":
                (key, label, window) = ("h5", "5H WINDOW", hour5)
            case "weekly_all":
                (key, label) = ("d7", "7D WINDOW")
            case "weekly_scoped":
                var name = l.scope?.model?.display_name ?? ""
                if name.isEmpty { name = l.scope?.model?.id ?? "" }
                if name.isEmpty { continue }
                (key, label) = ("d7_" + name.lowercased(), "7D " + name.uppercased())
            default:
                continue
            }
            let p = l.percent?.value ?? 0
            var g = pct(key, label, p, l.resets_at?.ms ?? 0, window)
            switch l.severity {
            case "warning", "warn", "high": g.severity = "warn"
            case "critical", "crit", "exceeded", "blocked": g.severity = "crit"
            default: break
            }
            s.gauges.append(g)
            if key == "h5" { s.series = p }
        }
        if s.gauges.isEmpty {  // older response shape
            func add(_ key: String, _ label: String, _ w: Window?, _ window: TimeInterval) {
                guard let w else { return }
                s.gauges.append(pct(key, label, w.utilization?.value ?? 0, w.resets_at?.ms ?? 0, window))
            }
            add("h5", "5H WINDOW", u.five_hour, hour5)
            add("d7", "7D WINDOW", u.seven_day, week)
            add("opus", "7D OPUS", u.seven_day_opus, week)
            add("sonnet", "7D SONNET", u.seven_day_sonnet, week)
            if let w = u.five_hour { s.series = w.utilization?.value ?? 0 }
        }
        return s
    }

    static func extraFacts(_ u: Usage) -> [Fact] {
        var out: [Fact] = []
        if let rows = u.seven_day_breakdown?.rows, !rows.isEmpty {
            let parts = rows.compactMap { r -> String? in
                let p = r.percent?.value ?? 0
                return p > 0 ? (r.display_name ?? "").uppercased() + " \(Int(p + 0.5))%" : nil
            }
            if !parts.isEmpty { out.append(Fact("7D SPLIT", parts.joined(separator: " · "))) }
        }
        if let sp = u.spend, sp.enabled == true, let used = sp.used {
            var v = used.text
            if let limit = sp.limit { v += " / " + limit.text }
            out.append(Fact("EXTRA", v))
        } else if let e = u.extra_usage {
            var v = "OFF"
            if e.is_enabled == true {
                let div = e.decimal_places.map { pow(10, $0.value) } ?? 100  // older responses: credits in cents
                v = money((e.used_credits?.value ?? 0) / div) + " / " + money((e.monthly_limit?.value ?? 0) / div)
            }
            out.append(Fact("EXTRA", v))
        }
        return out
    }

    /// Maps the keychain subscription fields to a price-table id.
    static func plan(_ sub: String, _ tier: String) -> String {
        let sub = sub.lowercased(), tier = tier.lowercased()
        switch sub {
        case "max": return tier.contains("20x") ? "claude_max_20x" : "claude_max_5x"
        case "pro": return "claude_pro"
        case "team": return "claude_team"
        default: return ""
        }
    }
}
