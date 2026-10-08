// Polls every provider on its own interval, keeps the card state, and
// publishes changes. One task per source; the actor serialises the state.
import Foundation

public enum Update: Sendable {
    case source(Source)
    case total(MonthTotal)
}

public struct Item: Sendable {
    public var provider: any Provider
    public var interval: TimeInterval  // 0: a link-only card
    public var monthlyUSD: Double?

    public init(_ provider: any Provider, interval: TimeInterval, monthlyUSD: Double? = nil) {
        self.provider = provider
        self.interval = interval
        self.monthlyUSD = monthlyUSD
    }
}

actor Scheduler {
    static let manualCooldown: TimeInterval = 15
    static let deadAfterFails = 5
    static let fetchTimeout: Duration = .seconds(45)
    static let sparkPoints = 60

    final class Entry {
        let p: any Provider
        let interval: TimeInterval
        let monthly: Double?
        var snap: Snapshot?
        var snapAt: Date?  // when snap was fetched: its values are as of then
        var lastOk: Date?
        var fetchedAt: Date?
        var next: Date?
        var cooldown: Date?
        var lastErr = ""
        var authHint = ""
        var fails = 0
        var fetching = false
        var showFetch = false  // manual refresh in flight: show SYNC on the card
        var lastStatus: Status = .unknown
        var plans: [String] = []  // distinct subscription plans seen this month, in order
        var plansMonth = ""
        var pendingManual = false
        var sleeper: Task<Void, Never>?

        init(_ it: Item) {
            p = it.provider
            interval = it.interval
            monthly = it.monthlyUSD
        }

        var name: String { p.name }
    }

    private let entries: [Entry]
    let byName: [String: Entry]
    let hist: HistoryStore
    let now: @Sendable () -> Date
    private let calendar: Calendar
    private let thresholds: Config.Thresholds
    private var continuation: AsyncStream<Update>.Continuation?
    private var lastTotal: Data?
    /// The API-price estimate of subscription usage, pushed by the tracker.
    private var apiCost: APICost?

    init(
        _ items: [Item], historyDir: String?, historyWritable: Bool = true, calendar: Calendar = .current,
        thresholds: Config.Thresholds = .init(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.thresholds = thresholds
        entries = items.map(Entry.init)
        byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        hist = HistoryStore(dir: historyDir, writable: historyWritable, calendar: calendar)
        self.now = now
        self.calendar = calendar
        let t = now()
        for e in entries { hist.load(e.name, now: t) }
    }

    func setContinuation(_ c: AsyncStream<Update>.Continuation) { continuation = c }

    func setAPICost(_ c: APICost?) {
        apiCost = c
        publishTotal()
    }

    /// Runs until cancelled.
    func run() async {
        await withTaskGroup(of: Void.self) { g in
            var i = 0
            for e in entries where e.interval > 0 {
                let name = e.name, first = TimeInterval(i) * 0.4
                g.addTask { await self.loop(name, first: first) }
                i += 1
            }
            g.addTask { await self.tick() }
        }
    }

    /// Status can age into stale/dead without any fetch happening; also catches the month rollover.
    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            let t = now()
            for e in entries where status(e, t) != e.lastStatus { publish(e) }
            publishTotal()
        }
    }

    private func loop(_ name: String, first: TimeInterval) async {
        guard let e = byName[name] else { return }
        e.next = now().addingTimeInterval(first)
        var delay = first
        while !Task.isCancelled {
            if !e.pendingManual {
                let d = delay
                let sleeper = Task.detached { _ = try? await Task.sleep(for: .seconds(d)) }
                e.sleeper = sleeper
                await withTaskCancellationHandler {
                    await sleeper.value
                } onCancel: {
                    sleeper.cancel()
                }
                e.sleeper = nil
                if Task.isCancelled { return }
            }
            let manual = e.pendingManual
            e.pendingManual = false
            (e.fetching, e.showFetch) = (true, manual)
            publish(e)
            let result = await Self.fetch(e.p)
            if Task.isCancelled { return }
            delay = apply(e, result)
            publish(e)
        }
    }

    static func fetch(_ p: any Provider) async -> Result<Snapshot, any Error> {
        await withTaskGroup(of: Result<Snapshot, any Error>?.self) { g in
            g.addTask {
                do { return .success(try await p.fetch()) } catch { return .failure(error) }
            }
            g.addTask {
                try? await Task.sleep(for: fetchTimeout)
                return Task.isCancelled ? nil : .failure(ProviderError.failed("context deadline exceeded"))
            }
            var out: Result<Snapshot, any Error> = .failure(CancellationError())
            for await r in g {
                if let r {
                    out = r
                    break
                }
            }
            g.cancelAll()
            return out
        }
    }

    /// Records a fetch result and returns the delay until the next one.
    func apply(_ e: Entry, _ r: Result<Snapshot, any Error>) -> TimeInterval {
        let t = now()
        (e.fetching, e.showFetch) = (false, false)
        e.fetchedAt = t
        let d: TimeInterval
        switch r {
        case .success(let snap):
            (e.snap, e.snapAt, e.lastOk, e.lastErr, e.authHint, e.fails) = (snap, t, t, "", "", 0)
            if let v = snap.series { hist.add(e.name, at: t, v) }
            let m = month(t)
            if m != e.plansMonth { (e.plans, e.plansMonth) = ([], m) }
            if !snap.plan.isEmpty, e.plans.last != snap.plan { e.plans.append(snap.plan) }
            d = Self.jitter(e.interval, .random(in: 0..<1))
        case .failure(ProviderError.auth(let hint)):
            // expired login: keep the last data, retry at the normal pace, no escalation
            (e.authHint, e.lastErr) = (hint, "")
            d = Self.jitter(e.interval, .random(in: 0..<1))
        case .failure(ProviderError.retryAfter(let after)):
            e.fails += 1
            e.lastErr = "RATE LIMITED (429) — BACKING OFF"
            d = max(after, Self.backoff(e.interval, e.fails))
        case .failure(let err):
            e.fails += 1
            e.lastErr = err.message
            d = Self.backoff(e.interval, e.fails)
        }
        e.next = t.addingTimeInterval(d)
        return d
    }

    /// Spreads requests ±10% around the interval; r is in [0,1).
    static func jitter(_ interval: TimeInterval, _ r: Double) -> TimeInterval { interval * (0.9 + 0.2 * r) }

    /// After n consecutive failures: 30s, 1m, 2m… never slower than 2× interval.
    static func backoff(_ interval: TimeInterval, _ n: Int) -> TimeInterval {
        let d = 30 * pow(2, Double(min(n - 1, 10)))
        return min(d, max(2 * interval, 60))
    }

    func status(_ e: Entry, _ t: Date) -> Status {
        if e.interval == 0 { return .link }
        if e.showFetch || (e.fetching && e.snap == nil && e.lastErr.isEmpty && e.authHint.isEmpty) { return .fetching }
        if e.fails >= Self.deadAfterFails { return .dead }
        guard let lastOk = e.lastOk else {
            if !e.authHint.isEmpty { return .stale }
            if !e.lastErr.isEmpty { return .error }
            return .fetching
        }
        let age = t.timeIntervalSince(lastOk)
        if age > 6 * e.interval { return .dead }
        if !e.authHint.isEmpty { return .stale }
        if !e.lastErr.isEmpty { return .error }
        if age > 2 * e.interval { return .stale }
        return .ok
    }

    private func source(_ e: Entry, _ t: Date) -> Source {
        var src = Source(
            name: e.name, title: e.p.title, status: status(e, t), interval: ms(e.interval),
            link: e.p.link, note: e.p.note.isEmpty ? nil : e.p.note,
            fetchedAt: e.fetchedAt.map(ms) ?? 0, lastOkAt: e.lastOk.map(ms) ?? 0,
            nextRefreshAt: e.next.map(ms) ?? 0, cooldownUntil: e.cooldown.map(ms) ?? 0,
            lastError: e.lastErr, hint: e.authHint)
        e.lastStatus = src.status
        guard let snap = e.snap else { return src }
        // at fetch time, so a stale card keeps the last known pace instead of drifting down
        src.gauges = Self.mark(Pace.fill(snap.gauges, at: e.snapAt ?? t), thresholds)
        src.facts = snap.facts
        if src.hint.isEmpty { src.hint = snap.hint }
        if let series = snap.series {
            src.spark = hist.spark(e.name, now: t, n: Self.sparkPoints)
            let kind = snap.gauges.first?.kind ?? ""
            if kind == "money" || kind == "credits", let burn = hist.burn(e.name, now: t, balance: snap.balance) {
                src.facts.append(Fact("BURN", Self.amount(kind, burn) + "/H"))
                if snap.balance && burn > 0 { src.facts.append(Fact("RUN-OUT", Self.hours(series / burn))) }
            }
        }
        return src
    }

    static func amount(_ kind: String, _ v: Double) -> String { kind == "money" ? "$" + fixed(v, 2) : fixed(v, 1) }

    static func hours(_ h: Double) -> String {
        if h > 24 * 30 { return ">30D" }
        if h >= 48 { return "~" + fixed(h / 24, 0) + "D" }
        if h >= 1 { return "~" + fixed(h, 0) + "H" }
        return "~" + fixed(h * 60, 0) + "M"
    }

    private func publish(_ e: Entry) {
        continuation?.yield(.source(source(e, now())))
        publishTotal()
    }

    /// Fetches every source once, concurrently, and records the results.
    func pollOnce() async {
        let ps = entries.filter { $0.interval > 0 }.map { ($0.name, $0.p) }
        let results = await withTaskGroup(of: (String, Result<Snapshot, any Error>).self) { g in
            for (name, p) in ps { g.addTask { (name, await Self.fetch(p)) } }
            return await g.reduce(into: [(String, Result<Snapshot, any Error>)]()) { $0.append($1) }
        }
        for (name, r) in results { if let e = byName[name] { _ = apply(e, r) } }
    }

    /// Every card in order.
    func sources() -> [Source] {
        let t = now()
        return entries.map { source($0, t) }
    }

    /// Asks for an immediate fetch ("nil" = all sources). Returns the cooldown
    /// end (unix ms) and whether the request was accepted.
    func refresh(_ name: String?) -> (until: Int64, accepted: Bool) {
        let t = now()
        var until: Date?
        var accepted = false
        for e in entries where (name == nil || e.name == name) && e.interval > 0 {
            if let c = e.cooldown, t < c {
                until = max(until ?? c, c)
                continue
            }
            let c = t.addingTimeInterval(Self.manualCooldown)
            e.cooldown = c
            until = max(until ?? c, c)
            e.pendingManual = true
            e.sleeper?.cancel()
            accepted = true
            publish(e)
        }
        return (until.map(ms) ?? 0, accepted)
    }

    func known(_ name: String?) -> Bool { name == nil || byName[name!] != nil }

    // MARK: month total

    /// Subscriptions are named by what is paid for: Codex is the ChatGPT plan.
    static let subTitles = ["codex": "ChatGPT"]

    /// The user's thresholds on every limit, and on balances that have one.
    static func mark(_ gauges: [Meter], _ t: Config.Thresholds) -> [Meter] {
        gauges.map { g in
            var g = g
            if g.kind == "percent" { (g.warnAt, g.critAt) = (t.warnPct, t.critPct) }
            if g.warnBelow != nil { (g.warnBelow, g.critBelow) = (t.warnUSD, t.critUSD) }
            return g
        }
    }

    func month(_ t: Date) -> String {
        let c = calendar.dateComponents([.year, .month], from: t)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    /// The spend of the current calendar month: usage per source plus subscriptions.
    func total(_ t: Date) -> MonthTotal {
        var tot = MonthTotal(month: month(t), usage: 0, subs: 0, total: 0, estimate: false, items: [])
        var subs: [MonthItem] = []
        for e in entries where e.interval > 0 {
            let plan = e.snap?.plan ?? ""
            if !plan.isEmpty || e.monthly != nil {
                var it = MonthItem(name: e.name, title: Self.subTitles[e.name] ?? e.p.title, kind: "subscription", usd: 0)
                it.plan = Self.planLabel(plan)
                if e.plans.count > 1 {  // changed while burnrate was watching; not prorated
                    it.plan = e.plans.map(Self.planLabel).joined(separator: " → ")
                }
                if let m = e.monthly {
                    (it.usd, it.priceFrom) = (m, "config")
                } else if let p = Pricing.plans[plan] {
                    (it.usd, it.priceFrom) = (p, "table")
                } else {
                    it.missing = true
                }
                if (e.monthly ?? 1) > 0 { subs.append(it) }
                continue
            }
            guard let snap = e.snap else { continue }
            var it = MonthItem(name: e.name, title: e.p.title, kind: "usage", usd: 0)
            if let m = snap.monthUSD {
                it.usd = m
            } else if snap.unitUSD > 0 {
                if let (drop, since) = hist.monthDrop(e.name, now: t) {
                    (it.usd, it.estimate) = (drop * snap.unitUSD, true)
                    if since > hist.monthStart(t) { (it.partial, it.since) = (true, ms(since)) }
                } else {
                    it.missing = true
                }
            } else {
                continue  // nothing to say about money for this source
            }
            tot.items.append(it)
        }
        tot.items += subs
        for it in tot.items {
            if it.kind == "usage" { tot.usage += it.usd } else { tot.subs += it.usd }
            tot.estimate = tot.estimate || it.estimate == true
        }
        (tot.usage, tot.subs) = (round2(tot.usage), round2(tot.subs))
        tot.total = round2(tot.usage + tot.subs)
        tot.api = apiCost
        return tot
    }

    /// claude_max_20x → "MAX 20X".
    static func planLabel(_ p: String) -> String {
        var p = p
        for pre in ["claude_", "chatgpt_"] where p.hasPrefix(pre) { p.removeFirst(pre.count) }
        return p.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    /// Sends the month total when it changed since the last send.
    private func publishTotal() {
        let t = total(now())
        let b = try? JSONEncoder.sorted.encode(t)
        guard b != lastTotal else { return }
        lastTotal = b
        continuation?.yield(.total(t))
    }
}

func round2(_ v: Double) -> Double { (v * 100).rounded(.toNearestOrAwayFromZero) / 100 }

extension JSONEncoder {
    /// Stable output for comparisons and dumps.
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
