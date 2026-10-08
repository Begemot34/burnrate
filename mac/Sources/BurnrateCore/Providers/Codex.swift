// Codex asks the Codex CLI for the plan's rate-limit windows over its
// documented app-server protocol (account/rateLimits/read), so the token never
// leaves Codex. With unofficial set it then tries chatgpt.com directly, which
// also reports per-model availability. Falls back to the newest session log.
import Foundation

public struct Codex: Provider {
    var deps: Deps
    var home: String  // ~/.codex
    var baseURL = "https://chatgpt.com"
    var appServer = ["codex", "-s", "read-only", "-a", "never", "app-server"]
    var unofficial = false

    public init(deps: Deps, home: String, unofficial: Bool = false) {
        self.deps = deps
        self.home = home
        self.unofficial = unofficial
    }

    public var name: String { "codex" }
    public var title: String { "Codex" }
    public var link: String { "https://chatgpt.com/codex/settings/usage" }
    public var note: String { "" }

    /// Covers both the HTTP (primary_window) and session-log (primary) spellings.
    struct Window: Decodable {
        var used_percent: LooseNumber?
        var reset_at: Epoch?
        var resets_at: Epoch?
        var reset_after_seconds: LooseNumber?
        var limit_window_seconds: LooseNumber?
        var window_minutes: LooseNumber?

        var minutes: Double { window_minutes?.value ?? 0 }
        var seconds: Double { limit_window_seconds?.value ?? 0 }
    }

    struct Credits: Decodable {
        var has_credits: Bool?
        var unlimited: Bool?
        var balance: LooseNumber?
    }

    struct Limits: Decodable {
        struct RateLimit: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        struct ModelUsage: Decodable {
            var available: Bool?
            var available_at: Epoch?
        }
        struct ResetCredits: Decodable {
            var available_count: LooseNumber?
        }
        var plan_type: String?
        var primary: Window?
        var secondary: Window?
        var credits: Credits?
        var rate_limit: RateLimit?
        /// Per-model availability, e.g. {"gpt-6-astra": {"available": true}}.
        var model_usage: [String: ModelUsage]?
        /// Per-model windows; null so far, shape guessed from rate_limit.
        var additional: [NamedWindow] = []
        var rate_limit_reset_credits: ResetCredits?
        /// Per-model buckets from the app-server.
        var extra: [NamedWindow] = []
        /// rateLimitReachedType from the app-server.
        var reached = ""

        enum CodingKeys: String, CodingKey {
            case plan_type, primary, secondary, credits, rate_limit, model_usage, rate_limit_reset_credits
            case additional_rate_limits
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plan_type = try c.decodeIfPresent(String.self, forKey: .plan_type)
            primary = try c.decodeIfPresent(Window.self, forKey: .primary)
            secondary = try c.decodeIfPresent(Window.self, forKey: .secondary)
            credits = try c.decodeIfPresent(Credits.self, forKey: .credits)
            rate_limit = try c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
            model_usage = try c.decodeIfPresent([String: ModelUsage].self, forKey: .model_usage)
            rate_limit_reset_credits = try c.decodeIfPresent(ResetCredits.self, forKey: .rate_limit_reset_credits)
            additional = (try? c.decodeIfPresent(Additional.self, forKey: .additional_rate_limits))?.windows ?? []
        }
    }

    struct NamedWindow {
        var key: String, label: String
        var w: Window
        /// Window length when the API leaves it out.
        var def: TimeInterval
    }

    public func fetch() async throws -> Snapshot {
        var err: Error
        do {
            return snapshot(try await fetchAppServer(), hint: "")
        } catch {
            err = error
        }
        if unofficial {
            do {
                return snapshot(try await fetchHTTP(), hint: "")
            } catch {
                err = error
            }
        }
        if let (local, at) = fromSessions() {
            let age = Self.durationString(minutesRounded: deps.now().timeIntervalSince(at))
            return snapshot(local, hint: "FROM LOCAL SESSION LOG, \(age.uppercased()) OLD · " + err.message)
        }
        throw err
    }

    /// A duration string of d rounded to the minute: "1h5m0s", "30m0s", "0s".
    static func durationString(minutesRounded d: TimeInterval) -> String {
        let m = Int((d / 60).rounded(.toNearestOrAwayFromZero))
        if m == 0 { return "0s" }
        let sign = m < 0 ? "-" : ""
        let a = abs(m)
        return a >= 60 ? "\(sign)\(a / 60)h\(a % 60)m0s" : "\(sign)\(a)m0s"
    }

    func fetchHTTP() async throws -> Limits {
        struct Auth: Decodable {
            struct Tokens: Decodable {
                var access_token: String?
                var account_id: String?
            }
            var tokens: Tokens?
        }
        guard let b = FileManager.default.contents(atPath: home + "/auth.json") else {
            throw ProviderError.auth("NO ~/.codex/auth.json — RUN CODEX LOGIN")
        }
        guard let tokens = (try? JSONDecoder().decode(Auth.self, from: b))?.tokens,
            let token = tokens.access_token, !token.isEmpty
        else { throw ProviderError.auth("CODEX NOT LOGGED IN WITH CHATGPT") }
        if let exp = Self.jwtExp(token), exp < deps.now() {
            throw ProviderError.auth("TOKEN EXPIRED — START CODEX ONCE TO RENEW")
        }
        var headers = ["Authorization": "Bearer " + token, "User-Agent": "codex_cli_rs"]
        if let id = tokens.account_id, !id.isEmpty { headers["ChatGPT-Account-Id"] = id }
        do {
            return try await HTTP.getJSON(deps, HTTP.request(baseURL + "/backend-api/wham/usage", headers))
        } catch  where error.isCode(401) {
            throw ProviderError.auth("TOKEN REJECTED — START CODEX ONCE TO RENEW")
        }
    }

    func snapshot(_ l: Limits, hint: String) -> Snapshot {
        var p = l.primary, s = l.secondary
        if let rl = l.rate_limit { (p, s) = (rl.primary_window, rl.secondary_window) }
        var out = Snapshot()
        out.hint = hint
        func add(_ key: String, _ label: String, _ w: Window?, _ def: TimeInterval) {
            guard let w else { return }
            var reset = w.reset_at?.ms ?? 0
            if reset == 0 { reset = w.resets_at?.ms ?? 0 }
            if reset == 0, let after = w.reset_after_seconds?.value, after > 0 {
                reset = ms(deps.now().addingTimeInterval(after.rounded(.towardZero)))
            }
            out.gauges.append(pct(key, label, w.used_percent?.value ?? 0, reset, Self.duration(w, def)))
        }
        add("h5", Self.label(p, "5H WINDOW"), p, hour5)
        add("d7", Self.label(s, "7D WINDOW"), s, week)
        if let p { out.series = p.used_percent?.value ?? 0 }
        for g in l.additional + l.extra { add(g.key, g.label, g.w, g.def) }
        if let plan = l.plan_type, !plan.isEmpty {
            out.facts.append(Fact("PLAN", plan.uppercased()))
            out.plan = "chatgpt_" + plan.lowercased()
        }
        for (n, m) in (l.model_usage ?? [:]).sorted(by: { $0.key < $1.key }) {
            var v = "OK"
            if m.available != true {
                v = "LOCKED"
                if let at = m.available_at?.ms, at > 0 { v += " UNTIL " + Self.shortDate(at) }
            }
            out.facts.append(Fact(n.uppercased(), v))
        }
        if !l.reached.isEmpty {
            out.facts.append(Fact("LIMIT", l.reached.replacingOccurrences(of: "_", with: " ").uppercased()))
        }
        if let n = l.rate_limit_reset_credits?.available_count?.value, n > 0 {
            out.facts.append(Fact("LIMIT RESETS", "\(Int(n))"))
        }
        if let cr = l.credits, cr.has_credits == true || cr.unlimited == true {
            out.facts.append(Fact("CREDITS", cr.unlimited == true ? "UNLIMITED" : money(cr.balance?.value ?? 0)))
        }
        return out
    }

    /// "Jan 2 15:04" in local time.
    static func shortDate(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The window length the API reports, or def when it says nothing.
    static func duration(_ w: Window, _ def: TimeInterval) -> TimeInterval {
        if w.minutes > 0 { return w.minutes * 60 }
        if w.seconds > 0 { return w.seconds }
        return def
    }

    static func label(_ w: Window?, _ def: String) -> String {
        guard let w else { return def }
        var min = w.minutes
        if min == 0 { min = w.seconds / 60 }
        if min == 300 { return "5H WINDOW" }
        if min == 10080 { return "7D WINDOW" }
        if min >= 1440 { return "\(Int(min / 1440))D WINDOW" }
        return def
    }

    static func prefix(_ w: Window, _ def: String) -> String {
        let l = label(w, "")
        return l.isEmpty ? def : String(l.dropLast(" WINDOW".count))
    }

    /// Reads per-model windows from additional_rate_limits: a list of
    /// {limit_name|model, rate_limit:{primary_window,…}} or a map keyed by model.
    /// Anything unrecognised yields nothing.
    struct Additional: Decodable {
        struct RL: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        struct Item: Decodable {
            var limit_name: String?
            var model: String?
            var metered_feature: String?
            var rate_limit: RL?
        }
        var windows: [NamedWindow] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { return }
            var list: [Item]
            if let l = try? c.decode([Item].self) {
                list = l
            } else {
                let m = try c.decode([String: RL].self)
                list = m.sorted { $0.key < $1.key }.map { Item(limit_name: $0.key, rate_limit: $0.value) }
            }
            for it in list {
                var name = it.limit_name ?? ""
                if name.isEmpty { name = it.model ?? "" }
                if name.isEmpty { name = it.metered_feature ?? "" }
                guard !name.isEmpty, let rl = it.rate_limit else { continue }
                windows += Codex.named(key: name.lowercased(), name: name, rl.primary_window, rl.secondary_window)
            }
        }
    }

    static func named(key: String, name: String, _ p: Window?, _ s: Window?) -> [NamedWindow] {
        var out: [NamedWindow] = []
        let up = name.uppercased()
        if let w = p { out.append(NamedWindow(key: key + "_p", label: prefix(w, "5H") + " " + up, w: w, def: hour5)) }
        if let w = s { out.append(NamedWindow(key: key + "_s", label: prefix(w, "7D") + " " + up, w: w, def: week)) }
        return out
    }

    // MARK: session logs

    /// The newest token_count event with rate-limit windows.
    func fromSessions() -> (Limits, Date)? {
        let root = URL(fileURLWithPath: home + "/sessions")
        let cutoff = deps.now().addingTimeInterval(-8 * 86400)
        var files: [(URL, Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        for case let u as URL in e where u.lastPathComponent.hasPrefix("rollout-") {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                let mod = v.contentModificationDate, mod > cutoff
            else { continue }
            files.append((u, mod))
        }
        files.sort { $0.1 > $1.1 }
        for (u, mod) in files.prefix(10) {
            if let (l, at) = Self.lastLimits(u) { return (l, at ?? mod) }
        }
        return nil
    }

    static func lastLimits(_ url: URL) -> (Limits, Date?)? {
        struct Event: Decodable {
            struct Payload: Decodable {
                var type: String?
                var rate_limits: Limits?
            }
            var timestamp: String?
            var payload: Payload?
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var best: (Limits, Date?)?
        let dec = JSONDecoder()
        Lines.each(data) { line in
            guard Lines.contains(line, "\"token_count\""), Lines.contains(line, "\"rate_limits\""),
                let ev = try? dec.decode(Event.self, from: Data(line)),
                let rl = ev.payload?.rate_limits, rl.primary != nil || rl.secondary != nil
            else { return }
            best = (rl, ev.timestamp.flatMap { RFC3339.parse($0) })
        }
        return best
    }

    static func jwtExp(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        struct Claims: Decodable { var exp: Int64? }
        guard let b = Data(base64Encoded: s), let exp = (try? JSONDecoder().decode(Claims.self, from: b))?.exp, exp != 0
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(exp))
    }
}

/// Byte-level line helpers for large JSONL files.
enum Lines {
    /// Calls body with each complete or trailing line, without the newline.
    static func each(_ data: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var start = 0
            let n = buf.count
            while start < n {
                let rest = n - start
                if let p = memchr(base + start, 10, rest) {
                    let end = base.distance(to: UnsafeRawPointer(p))
                    body(UnsafeRawBufferPointer(rebasing: buf[start..<end]))
                    start = end + 1
                } else {
                    body(UnsafeRawBufferPointer(rebasing: buf[start..<n]))
                    break
                }
            }
        }
    }

    static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}
