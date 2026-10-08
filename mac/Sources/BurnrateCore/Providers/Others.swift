// OpenRouter, Replicate and Higgsfield: balances and month spend.
import Foundation

// MARK: - OpenRouter

public struct OpenRouter: Provider {
    var deps: Deps
    var key: String
    var baseURL = "https://openrouter.ai"

    public init(deps: Deps, key: String) {
        self.deps = deps
        self.key = key
    }

    public var name: String { "openrouter" }
    public var title: String { "OpenRouter" }
    public var link: String { "https://openrouter.ai/settings/credits" }
    public var note: String { "" }

    struct KeyInfo: Decodable {
        struct D: Decodable {
            var label: String?
            var usage: LooseNumber?
            var usage_daily: LooseNumber?
            var usage_monthly: LooseNumber?
            var limit: LooseNumber?
            var limit_remaining: LooseNumber?
        }
        var data: D
    }

    struct CreditsInfo: Decodable {
        struct D: Decodable {
            var total_credits: LooseNumber?
            var total_usage: LooseNumber?
        }
        var data: D
    }

    public func fetch() async throws -> Snapshot {
        guard !key.isEmpty else { throw ProviderError.auth("NO OPENROUTER KEY — ADD IT IN SETTINGS ▸ PROVIDERS") }
        func get<T: Decodable>(_ path: String) async throws -> T {
            try await HTTP.getJSON(deps, HTTP.request(baseURL + path, ["Authorization": "Bearer " + key]))
        }
        let k: KeyInfo.D
        do {
            k = (try await get("/api/v1/key") as KeyInfo).data
        } catch  where error.isCode(401) {
            throw ProviderError.auth("OPENROUTER KEY REJECTED — CHECK IT IN SETTINGS")
        }
        var s = Snapshot()
        if let cr = try? await get("/api/v1/credits") as CreditsInfo {
            // no bar: total_credits is every purchase ever, a meaningless 100%
            let left = (cr.data.total_credits?.value ?? 0) - (cr.data.total_usage?.value ?? 0)
            s.gauges.append(moneyLeft("left", "CREDITS LEFT", left))
            (s.series, s.balance) = (left, true)
        } else if let rem = k.limit_remaining, let limit = k.limit {
            var g = moneyLeft("left", "KEY LIMIT LEFT", rem.value)
            g.max = limit.value
            s.gauges.append(g)
            (s.series, s.balance) = (rem.value, true)
        } else {
            s.hint = "BALANCE NEEDS A MANAGEMENT KEY"
            s.series = k.usage?.value ?? 0
        }
        let month = k.usage_monthly?.value ?? 0
        s.gauges += [
            Meter(key: "day", label: "SPENT TODAY", kind: "money", value: k.usage_daily?.value ?? 0),
            Meter(key: "month", label: "SPENT MONTH", kind: "money", value: month),
        ]
        s.monthUSD = month
        return s
    }
}

// MARK: - Replicate

/// Replicate's API has no billing: the account, spend and prepaid credit all come
/// from the website with the session cookie, so an API token would add nothing.
public struct Replicate: Provider {
    var deps: Deps
    var sessionID: String
    var webBase = "https://replicate.com"
    /// username and users|organizations, looked up once
    private let account = Locked<(user: String, kind: String)?>(nil)

    public init(deps: Deps, sessionID: String) {
        self.deps = deps
        self.sessionID = sessionID
    }

    public var name: String { "replicate" }
    public var title: String { "Replicate" }
    public var link: String { "https://replicate.com/account/billing" }
    public var note: String { "" }

    public func fetch() async throws -> Snapshot {
        guard !sessionID.isEmpty else {
            throw ProviderError.auth("NO REPLICATE SESSION — PASTE THE SESSIONID COOKIE IN SETTINGS")
        }
        func get(_ path: String) async throws -> Data {
            do {
                return try await HTTP.get(
                    deps,
                    HTTP.request(
                        webBase + "/api" + path,
                        ["Cookie": "sessionid=" + sessionID, "Referer": webBase + "/account/billing"]))
            } catch  where error.isCode(401, 403) {
                throw ProviderError.auth("SESSIONID COOKIE EXPIRED — PASTE A NEW ONE IN SETTINGS")
            }
        }
        let acc: (user: String, kind: String)
        if let a = account.withLock({ $0 }) {
            acc = a
        } else {
            struct Account: Decodable { var type: String?; var username: String? }
            let a = try HTTP.decode(Account.self, from: try await get("/account"), path: "/account")
            guard let user = a.username, !user.isEmpty else { throw ProviderError.failed("no username in /api/account") }
            acc = (user, a.type == "organization" ? "organizations" : "users")
            account.withLock { $0 = acc }
        }
        var s = Snapshot()
        s.facts = [Fact("USER", acc.user.uppercased())]
        let base = "/\(acc.kind)/\(acc.user)"
        let inv = try await get(base + "/invoices")
        guard let spent = Self.currentInvoice(inv) else {
            throw ProviderError.failed("no current monthly-usage invoice")
        }
        s.monthUSD = spent
        struct Unused: Decodable { var unused_credit: LooseNumber? }
        if let data = try? await get(base + "/unused-credit"),
            let uc = try? HTTP.decode(Unused.self, from: data, path: "/unused-credit")
        {
            // the balance leads the card, like OpenRouter; history tracks it
            let v = uc.unused_credit?.value ?? 0
            s.gauges.append(moneyLeft("left", "CREDITS LEFT", v))
            (s.series, s.balance) = (v, true)
        }
        s.gauges.append(Meter(key: "month", label: "SPENT MONTH", kind: "money", value: spent))
        return s
    }

    /// The open monthly-usage invoice in either a bare list or {results: [...]}.
    static func currentInvoice(_ raw: Data) -> Double? {
        struct Invoice: Decodable {
            var type: String?
            var ended_before: String?
            var total_cost_before_adjustments: LooseNumber?
            var total_cost: LooseNumber?
        }
        struct Wrap: Decodable { var invoices: [Invoice]?; var results: [Invoice]? }
        let dec = JSONDecoder()
        let list: [Invoice]
        if let l = try? dec.decode([Invoice].self, from: raw) {
            list = l
        } else if let w = try? dec.decode(Wrap.self, from: raw) {
            list = (w.invoices ?? []) + (w.results ?? [])
        } else {
            return nil
        }
        for i in list where i.type == "monthly-usage" && (i.ended_before ?? "").isEmpty {
            let v = i.total_cost_before_adjustments?.value ?? 0
            return v == 0 ? i.total_cost?.value ?? 0 : v
        }
        // fall back to the first monthly-usage one
        return list.first { $0.type == "monthly-usage" }.map { $0.total_cost_before_adjustments?.value ?? 0 }
    }
}

// MARK: - Higgsfield

public struct Higgsfield: Provider {
    var deps: Deps

    public init(deps: Deps) { self.deps = deps }

    public var name: String { "higgsfield" }
    public var title: String { "Higgsfield" }
    public var link: String { "https://higgsfield.ai" }
    public var note: String { "" }

    public func fetch() async throws -> Snapshot {
        let out: Data
        do {
            out = try await deps.exec(
                ["HIGGSFIELD_NO_UPDATE_CHECK": "1", "HIGGSFIELD_DISABLE_TELEMETRY": "1"],
                "higgsfield", ["account", "status", "--json"])
        } catch {
            let low = "\(error)".lowercased()
            if low.contains("login") || low.contains("auth") { throw ProviderError.auth("RUN HIGGSFIELD LOGIN") }
            throw error
        }
        struct Status: Decodable { var credits: LooseNumber?; var subscription_plan_type: String? }
        let st: Status
        do {
            st = try JSONDecoder().decode(Status.self, from: out)
        } catch {
            throw ProviderError.failed("higgsfield: \(describe(error))")
        }
        let c = st.credits?.value ?? 0
        var s = Snapshot()
        s.gauges = [Meter(key: "credits", label: "CREDITS", kind: "credits", value: c)]
        s.facts = [
            Fact("PLAN", (st.subscription_plan_type ?? "").uppercased()),
            Fact("≈ USD", money(c * Pricing.higgsfieldUSDPerCredit)),
        ]
        (s.series, s.balance, s.unitUSD) = (c, true, Pricing.higgsfieldUSDPerCredit)
        return s
    }
}
