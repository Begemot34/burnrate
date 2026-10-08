// The engine's logic, covered by these tests.
import Foundation
import Testing
@testable import BurnrateCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

/// A settable clock for the scheduler.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date {
        get { lock.withLock { t } }
        set { lock.withLock { t = newValue } }
    }
}

private struct Fake: Provider {
    var name = "x"
    var snap = Snapshot()
    var title: String { name }
    var link: String { "" }
    var note: String { "" }
    func fetch() async throws -> Snapshot { snap }
}

private func meter(
    _ key: String, kind: String = "percent", dir: String = "used", value: Double,
    resetAt: Int64?, window: Int64?
) -> Meter {
    Meter(key: key, label: key, kind: kind, value: value, dir: dir, resetAt: resetAt, window: window)
}

@Suite struct PaceTests {
    @Test func thresholdsMarkLimitsAndBalances() {
        var t = Config.Thresholds()
        (t.warnPct, t.critPct, t.warnUSD, t.critUSD) = (50, 80, 20, 8)
        let gauges = [
            Meter(key: "p", label: "P", kind: "percent", value: 60, max: 100, dir: "used"),
            Meter(key: "m", label: "M", kind: "money", value: 15, dir: "left", warnBelow: 10, critBelow: 5),
            Meter(key: "s", label: "S", kind: "money", value: 3),
        ]
        let out = Scheduler.mark(gauges, t)
        #expect(out[0].warnAt == 50 && out[0].critAt == 80 && Format.level(out[0], 60) == .warn)
        #expect(out[1].warnBelow == 20 && out[1].critBelow == 8 && Format.level(out[1], 15) == .warn)
        #expect(out[2].warnBelow == nil, "spend without a threshold stays plain")
    }

    let h: Int64 = 3_600_000
    var week: Int64 { 168 * h }
    let reset: Int64 = 1_800_000_000_000

    @Test func forecasts() {
        func at(_ left: Int64) -> Int64 { reset - left }
        let ok: [(String, Double, Int64, Int64, Double, Double)] = [
            ("half window", 50, week, at(84 * h), 100, 0.5),
            ("screenshot 7d", 13, week, at(week - week * 38 / 100), 13 / 0.38, 0.38),
            ("first day", 30, week, at(week - 24 * h), 30 * 7, 1.0 / 7),
            ("last hour", 95, week, at(h), 95 / (167.0 / 168), 167.0 / 168),
            ("at reset", 70, week, reset, 70, 1),
            ("zero used", 0, week, at(84 * h), 0, 0.5),
            ("exactly min elapsed", 5, 100 * h, at(90 * h), 50, 0.1),
        ]
        for (name, used, win, now, pace, elapsed) in ok {
            let f = Pace.forecast(used: used, resetAt: reset, window: win, now: now)
            #expect(f != nil, "\(name)")
            #expect(abs((f?.pace ?? -1) - pace) < 1e-9 && abs((f?.elapsed ?? -1) - elapsed) < 1e-9, "\(name)")
        }
        let none: [(String, Double, Int64, Int64, Int64)] = [
            ("too early", 5, reset, week, at(week - 10 * h)),
            ("reset passed", 80, reset, week, reset + 1),
            ("before window", 10, reset, week, reset - week - h),
            ("no window", 50, reset, 0, at(h)),
            ("no reset", 50, 0, week, at(h)),
            ("nan", .nan, reset, week, at(84 * h)),
            ("inf", .infinity, reset, week, at(84 * h)),
            ("overflow", .greatestFiniteMagnitude, reset, week, at(84 * h)),
        ]
        for (name, used, r, win, now) in none {
            #expect(Pace.forecast(used: used, resetAt: r, window: win, now: now) == nil, "\(name)")
        }
    }

    @Test func screenshot() {
        // "7d 13%→34% · Fable 18%→47% · (wk 38%)" from the reference status line
        let now = reset - week + week * 38 / 100
        for (used, want) in [(13.0, 34.0), (18.0, 47.0)] {
            #expect(Pace.forecast(used: used, resetAt: reset, window: week, now: now)?.pace.rounded() == want)
        }
    }

    @Test func levels() {
        let cases: [Double: String] = [
            0: "under", 79.49: "under", 79.5: "on", 80: "on", 100: "on", 110: "on",
            110.49: "on", 110.5: "over", 300: "over",
        ]
        for (p, want) in cases { #expect(Pace.level(p) == want, "\(p)") }
    }

    @Test func fillOnlyDayPlusUsedWindows() {
        let now = date(2026, 10, 6, 12)
        let wk: Int64 = 7 * 86_400_000
        let reset = ms(now.addingTimeInterval(7 * 86400 / 2))  // half the week gone
        let gs = [
            meter("h5", value: 40, resetAt: ms(now.addingTimeInterval(3600)), window: 5 * 3_600_000),
            meter("d7", value: 30, resetAt: reset, window: wk),
            meter("d7_x", value: 50, resetAt: reset, window: wk),
            meter("d7_y", value: 60, resetAt: reset, window: wk),
            meter("left", kind: "money", dir: "left", value: 5, resetAt: reset, window: wk),
            meter("nowin", value: 30, resetAt: reset, window: nil),
        ]
        let out = Pace.fill(gs, at: now)
        #expect(out[0].pace == nil && out[4].pace == nil && out[5].pace == nil)
        for (i, (pace, level)) in [(60.0, "under"), (100.0, "on"), (120.0, "over")].enumerated() {
            let g = out[i + 1]
            #expect(g.pace == pace && g.paceLevel == level && g.elapsed == 50, "\(g.key)")
        }
    }
}

@Suite struct SchedulerTests {
    @Test func jitterBounds() {
        for r in [0, 0.5, 0.9999] {
            let d = Scheduler.jitter(60, r)
            #expect(d >= 54 && d <= 66)
        }
    }

    @Test func backoff() {
        for (i, w) in [30.0, 60, 120, 240, 240].enumerated() { #expect(Scheduler.backoff(120, i + 1) == w) }
        #expect(Scheduler.backoff(600, 40) == 1200, "cap at 2× interval")
    }

    private func scheduler(_ items: [Item], _ clock: Clock) -> Scheduler {
        Scheduler(items, historyDir: nil, calendar: utc, now: { clock.now })
    }

    @Test func statusLifecycle() async {
        let clock = Clock(date(2026, 10, 6, 12))
        let s = scheduler([Item(Fake(), interval: 60)], clock)
        func st() async -> Status { await s.sources()[0].status }

        #expect(await st() == .fetching, "no data yet")
        var snap = Snapshot()
        snap.gauges = [meter("a", value: 1, resetAt: nil, window: nil)]
        await s.applyNamed("x", .success(snap))
        #expect(await st() == .ok)
        clock.now += 180
        #expect(await st() == .stale, "3× interval")
        let d = await s.applyNamed("x", .failure(ProviderError.retryAfter(300)))
        let afterRetry = await st()
        #expect(d == 300 && afterRetry == .error, "retry-after wins")
        let kept = await s.sources()[0].gauges.count
        #expect(kept == 1, "last good value kept")
        for _ in 0..<Scheduler.deadAfterFails { await s.applyNamed("x", .failure(ProviderError.failed("boom"))) }
        #expect(await st() == .dead)
        await s.applyNamed("x", .success(Snapshot()))
        #expect(await st() == .ok, "recovers")
        await s.applyNamed("x", .failure(ProviderError.auth("login")))
        let authSrc = await s.sources()[0]
        #expect(authSrc.status == .stale && authSrc.hint == "login")
        clock.now += 420
        #expect(await st() == .dead, "6× interval")
    }

    @Test func errorsAreScrubbed() async {
        let s = scheduler([Item(Fake(), interval: 60)], Clock(date(2026, 10, 6)))
        await s.applyNamed("x", .failure(ProviderError.http(500, "bad key sk-or-v1-abcdefghijklmnop")))
        let err = await s.sources()[0].lastError
        #expect(err == "HTTP 500: bad key sk-or-v1-…")
    }

    @Test func manualCooldown() async {
        let clock = Clock(date(2026, 10, 6, 12))
        let s = scheduler([Item(Fake(), interval: 60)], clock)
        #expect(await s.refresh(nil).accepted, "first refresh accepted")
        let r = await s.refresh("x")
        #expect(!r.accepted && r.until == ms(clock.now.addingTimeInterval(Scheduler.manualCooldown)))
        clock.now += Scheduler.manualCooldown + 1
        #expect(await s.refresh("x").accepted, "after cooldown")
    }

    @Test func sourceEncodesEmptyLists() async throws {
        let s = scheduler([Item(Fake(), interval: 60)], Clock(date(2026, 10, 6)))
        var snap = Snapshot()
        snap.facts = [Fact("USER", "me")]
        await s.applyNamed("x", .success(snap))
        let src = await s.sources()[0]
        let json = String(decoding: try JSONEncoder().encode(src), as: UTF8.self)
        #expect(json.contains(#""gauges":[]"#), "gauges must encode as [], not be missing")
    }

    @Test func monthTotal() async {
        func snap(_ f: (inout Snapshot) -> Void) -> Snapshot { var s = Snapshot(); f(&s); return s }
        let items = [
            Item(Fake(name: "claude", snap: snap { $0.plan = "claude_max_20x" }), interval: 60),
            Item(Fake(name: "codex", snap: snap { $0.plan = "chatgpt_pro" }), interval: 60, monthlyUSD: 100),
            Item(Fake(name: "or", snap: snap { $0.monthUSD = 31.58 }), interval: 60),
            Item(Fake(name: "hf", snap: snap { ($0.series, $0.balance, $0.unitUSD) = (400, true, 0.05) }), interval: 60),
            Item(Fake(name: "rep"), interval: 60),  // never fetched: absent
        ]
        let clock = Clock(date(2026, 10, 6, 12))
        let s = scheduler(items, clock)
        await s.addHistory("hf", date(2026, 10, 3), 500)
        for it in items.prefix(4) {
            let snap = try! await it.provider.fetch()
            await s.applyNamed(it.provider.name, .success(snap))
        }
        let tot = await s.total(clock.now)
        #expect(tot.month == "2026-10" && tot.usage == 36.58 && tot.subs == 300 && tot.total == 336.58 && tot.estimate)
        let by = Dictionary(uniqueKeysWithValues: tot.items.map { ($0.name, $0) })
        #expect(by["claude"]?.priceFrom == "table" && by["claude"]?.plan == "MAX 20X")
        #expect(by["codex"]?.priceFrom == "config" && by["codex"]?.title == "ChatGPT")
        #expect(by["hf"]?.partial == true && by["hf"]?.usd == 5 && tot.items.last?.kind == "subscription")
        #expect(by["rep"] == nil, "unfetched source must not appear")
    }

    @Test func paceHiddenAndStale() async {
        let clock = Clock(date(2026, 10, 6, 12))
        let s = scheduler([Item(Fake(), interval: 60)], clock)
        let wk: Int64 = 7 * 86_400_000
        func g(_ key: String, _ left: TimeInterval) -> Meter {
            meter(key, value: 50, resetAt: ms(clock.now.addingTimeInterval(left)), window: wk)
        }
        var snap = Snapshot()
        snap.gauges = [g("half", 7 * 86400 / 2), g("early", 7 * 86400 - 3600), g("passed", -60)]
        await s.applyNamed("x", .success(snap))
        var src = await s.sources()[0]
        #expect(src.gauges[0].pace == 100)
        #expect(src.gauges[1].pace == nil && src.gauges[2].pace == nil, "hidden before 10% and after the reset")
        clock.now += 48 * 3600  // provider goes quiet: the card keeps the pace as of the fetch
        src = await s.sources()[0]
        #expect(src.gauges[0].pace == 100 && src.gauges[0].elapsed == 50)
    }

    @Test func formats() {
        #expect(Scheduler.hours(1000) == ">30D" && Scheduler.hours(50) == "~2D" && Scheduler.hours(5) == "~5H")
        #expect(Scheduler.hours(0.5) == "~30M")
        #expect(Scheduler.amount("money", 1.234) == "$1.23" && Scheduler.amount("credits", 2.25) == "2.2")
        #expect(Scheduler.planLabel("claude_max_20x") == "MAX 20X" && Scheduler.planLabel("chatgpt_plus") == "PLUS")
    }
}

extension Scheduler {
    @discardableResult
    func applyNamed(_ name: String, _ r: Result<Snapshot, any Error>) -> TimeInterval {
        apply(byName[name]!, r)
    }

    func addHistory(_ name: String, _ t: Date, _ v: Double) { hist.add(name, at: t, v) }
}

@Suite struct HistoryTests {
    @Test func burnAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = HistoryStore(dir: dir, calendar: utc)
        let t0 = date(2026, 10, 6, 6)
        for i in 0...4 { s.add("or", at: t0.addingTimeInterval(Double(i) * 3600), 100 - Double(i) * 10) }
        let now = t0.addingTimeInterval(4 * 3600)
        #expect(s.burn("or", now: now, balance: true) == 10)
        #expect(s.burn("or", now: now, balance: false) == nil, "spent series going down is a reset, not burn")
        let s2 = HistoryStore(dir: dir, calendar: utc)
        s2.load("or", now: now)
        let sp = s2.spark("or", now: now, n: 60)
        #expect(sp?.count == 5 && sp?.first == 100)
        let text = try String(contentsOfFile: dir + "/or.jsonl", encoding: .utf8)
        #expect(text.hasPrefix(#"{"t":1791266400000,"v":100}"#), "one JSON object per line")
    }

    @Test func readsGoLines() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{\"t\":1791266400000,\"v\":18.42}\ngarbage\n{\"t\":1791270000000,\"v\":17.5}\n"
            .write(toFile: dir + "/or.jsonl", atomically: true, encoding: .utf8)
        let s = HistoryStore(dir: dir, calendar: utc)
        s.load("or", now: date(2026, 10, 6, 8))
        #expect(s.series["or"]?.map(\.v) == [18.42, 17.5])
    }

    @Test func monthDrop() {
        let s = HistoryStore(dir: nil, calendar: utc)
        let now = date(2026, 10, 6, 12)
        // history starts mid-month: partial, since = first point
        s.add("hf", at: date(2026, 10, 3), 500)
        s.add("hf", at: date(2026, 10, 4), 450)
        s.add("hf", at: date(2026, 10, 5), 800)  // top-up, ignored
        s.add("hf", at: date(2026, 10, 6), 700)
        let r = s.monthDrop("hf", now: now)
        #expect(r?.drop == 150 && r?.since == date(2026, 10, 3))
        // a point before the 1st is the baseline: whole month covered
        s.add("b", at: date(2026, 9, 30, 20), 100)
        s.add("b", at: date(2026, 10, 2), 90)
        let b = s.monthDrop("b", now: now)
        #expect(b?.drop == 10 && b?.since == date(2026, 10, 1))
        #expect(s.monthDrop("none", now: now) == nil)
    }
}

@Suite struct ConfigTests {
    @Test func durationsAndEnv() throws {
        #expect(DurationString.parse("5m0s") == 300 && DurationString.parse("2m") == 120 && DurationString.parse("1h30m") == 5400)
        #expect(DurationString.parse("1.5s") == 1.5 && DurationString.parse("0") == 0 && DurationString.parse("5x") == nil)
        #expect(DurationString.format(300) == "5m0s" && DurationString.format(5400) == "1h30m0s" && DurationString.format(15) == "15s")

        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try """
        {"env_file":"\(dir)/pipe.env",
         "providers":{"codex":{"enabled":true,"interval":"1m","unofficial":true,"monthly_usd":0}}}
        """.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        try "# c\nexport OPENROUTER_API_KEY=\"a\"\nREPLICATE_SESSIONID='s'\n".write(toFile: dir + "/pipe.env", atomically: true, encoding: .utf8)
        let keychain = FakeKeychain(["OPENROUTER_API_KEY": "b"])
        let c = try Config.load(dir, keychain: keychain.run)
        #expect(c.secrets == ["OPENROUTER_API_KEY": "b", "REPLICATE_SESSIONID": "s"], "the Keychain wins")
        #expect(try Config.load(dir, keychain: nil).secrets["OPENROUTER_API_KEY"] == "a")
        #expect(c.providers["codex"] == .init(enabled: true, interval: 60, monthlyUSD: 0, unofficial: true))
        #expect(c.providers["claude"]?.interval == 300, "missing providers keep the defaults")
        #expect(c.historyDir.hasPrefix("/"), "~ expanded")
    }

    @Test func initWritesLoadableFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try Config.initFiles(dir).count == 1)
        #expect(try Config.initFiles(dir).isEmpty)
        #expect(try Config.load(dir, keychain: nil).providers["higgsfield"]?.interval == 600)
    }

    @Test func saveKeepsOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"codex_home":"/x","extra":[1],"providers":{"codex":{"enabled":true,"interval":"1m","unofficial":true,"monthly_usd":20,"note":"mine"}}}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        var c = try Config.load(dir, keychain: nil)
        c.providers["codex"]?.monthlyUSD = nil
        c.providers["claude"]?.monthlyUSD = 0
        c.providers["higgsfield"]?.enabled = false
        c.thresholds.warnPct = 60
        try c.save()

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/config.json"))) as! [String: Any]
        #expect(raw["codex_home"] as? String == "/x" && raw["extra"] != nil, "unknown keys stay")
        let codex = (raw["providers"] as! [String: Any])["codex"] as! [String: Any]
        #expect(codex["note"] as? String == "mine" && codex["monthly_usd"] == nil && codex["enabled"] as? Bool == true)

        let back = try Config.load(dir, keychain: nil)
        #expect(back.providers["codex"] == .init(enabled: true, interval: 60, monthlyUSD: nil, unofficial: true))
        #expect(back.providers["claude"]?.monthlyUSD == 0 && back.providers["claude"]?.enabled == true)
        #expect(back.providers["higgsfield"]?.enabled == false && back.providers["higgsfield"]?.interval == 600)
        #expect(back.thresholds.warnPct == 60 && back.thresholds.critUSD == 5)
        let mode = try FileManager.default.attributesOfItem(atPath: dir + "/config.json")[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func saveCreatesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var c = try Config.load(dir, keychain: nil)
        c.providers["replicate"]?.interval = 1800
        try c.save()
        #expect(try Config.load(dir, keychain: nil).providers["replicate"]?.interval == 1800)
    }
}

/// /usr/bin/security over a dictionary: find, delete and `-i` add lines.
final class FakeKeychain: Sendable {
    let items: Locked<[String: String]>
    let calls = Locked<[([String], String?)]>([])

    init(_ items: [String: String] = [:]) { self.items = Locked(items) }

    var run: Keychain.Run {
        { [self] args, input in
            calls.withLock { $0.append((args, input)) }
            let account = args.firstIndex(of: "-a").map { args[$0 + 1] } ?? ""
            switch args.first {
            case "find-generic-password":
                guard let v = items.withLock({ $0[account] }) else { return (Data(), 44) }
                return (Data((v + "\n").utf8), 0)
            case "delete-generic-password":
                return (Data(), items.withLock { $0.removeValue(forKey: account) } == nil ? 44 : 0)
            case "-i":
                // add-generic-password -U -s burnrate -a NAME -w "value"
                let line = input ?? ""
                guard let a = line.range(of: " -a "), let w = line.range(of: " -w \"") else { return (Data(), 1) }
                let name = String(line[a.upperBound...].prefix { $0 != " " })
                var v = String(line[w.upperBound...].dropLast(2))
                v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                items.withLock { $0[name] = v }
                return (Data(), 0)
            default:
                return (Data(), 1)
            }
        }
    }
}

@Suite struct KeychainTests {
    @Test func writeKeepsTheValueOutOfArgv() throws {
        let k = FakeKeychain()
        try Keychain.write("OPENROUTER_API_KEY", " sk-or-v1-secret\"x\n", k.run)
        let add = try #require(k.calls.withLock { $0.first })
        #expect(add.0 == ["-i"] && add.1?.contains("sk-or-v1-secret") == true)
        #expect(!k.calls.withLock { $0 }.contains { $0.0.joined().contains("secret") })
        #expect(Keychain.read("OPENROUTER_API_KEY", k.run) == "sk-or-v1-secret\"x")
    }

    @Test func rejectsUnknownNamesAndNewlines() {
        let k = FakeKeychain()
        #expect(throws: (any Error).self) { try Keychain.write("HOME", "x", k.run) }
        #expect(throws: (any Error).self) { try Keychain.write("REPLICATE_SESSIONID", "a\nb", k.run) }
        // security -i reads ~4 KB lines: a longer value would spill into a second command
        #expect(throws: (any Error).self) {
            try Keychain.write("REPLICATE_SESSIONID", String(repeating: "A", count: 5000) + " delete-keychain", k.run)
        }
        for bad in ["a\0b", "a b", "a\u{2028}b", "café"] {
            #expect(throws: (any Error).self) { try Keychain.write("REPLICATE_SESSIONID", bad, k.run) }
        }
        #expect(k.calls.withLock { $0 }.isEmpty)
    }

    @Test func readAllAndDelete() throws {
        let k = FakeKeychain(["REPLICATE_SESSIONID": "s1", "OTHER": "x"])
        #expect(Keychain.readAll(k.run) == ["REPLICATE_SESSIONID": "s1"])
        try Keychain.delete("REPLICATE_SESSIONID", k.run)
        try Keychain.delete("REPLICATE_SESSIONID", k.run)  // already gone is fine
        #expect(Keychain.readAll(k.run).isEmpty)
    }

    @Test func sessionIDFromPaste() {
        #expect(Keychain.sessionID(from: " abc123 ") == "abc123")
        #expect(Keychain.sessionID(from: "sessionid=abc123") == "abc123")
        #expect(Keychain.sessionID(from: "Cookie: csrftoken=z; sessionid=abc123; other=1") == "abc123")
        #expect(Keychain.sessionID(from: "csrftoken=z") == "")
    }

    @Test func masks() {
        #expect(Keychain.mask("sk-or-v1-0123456789abcd") == "sk-o…abcd")
        #expect(Keychain.mask("short") == "••••••••")
    }
}

@Suite struct LooseJSONTests {
    struct T: Decodable { var n: LooseNumber?; var e: Epoch? }

    private func decode(_ s: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(s.utf8)) }

    @Test func numbersAndEpochs() throws {
        #expect(try decode(#"{"n":"12.5"}"#).n?.value == 12.5)
        #expect(try decode(#"{"n":3}"#).n?.value == 3)
        #expect(try decode(#"{"n":""}"#).n?.value == 0)
        #expect(try decode(#"{"e":1791266400}"#).e?.ms == 1_791_266_400_000, "seconds")
        #expect(try decode(#"{"e":1791266400123}"#).e?.ms == 1_791_266_400_123, "ms")
        #expect(try decode(#"{"e":"2026-10-06T06:00:00Z"}"#).e?.ms == 1_791_266_400_000)
        #expect(try decode(#"{"e":"2026-10-06T09:00:00.5+03:00"}"#).e?.ms == 1_791_266_400_500)
        #expect(try decode(#"{"e":null}"#).e == nil)
        #expect(throws: (any Error).self) { try decode(#"{"e":"yesterday"}"#) }
    }

    @Test func scrub() {
        #expect(Scrub.text("key sk-or-v1-abcdefghij and Bearer eyJhbGciOiJ.x") == "key sk-or-v1-… and Bearer …")
        #expect(Scrub.text("r8_abcdefghijk") == "r8_abcd…")
    }
}
