// Answers "what would the last 30 days cost at API prices": reads the token
// counts Claude Code and Codex log on this Mac and prices them with the
// per-token list prices OpenRouter publishes.
//
// The logs are big (gigabytes of Claude Code sessions a month), so files are
// read once from a saved offset per file, lines are filtered on raw bytes
// before any JSON decoding, and the scan runs on its own serial queue.
import Foundation

/// Token counts of one model.
struct Usage: Equatable {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite5m = 0.0, cacheWrite1h = 0.0

    static func += (a: inout Usage, b: Usage) {
        a.input += b.input
        a.output += b.output
        a.cacheRead += b.cacheRead
        a.cacheWrite5m += b.cacheWrite5m
        a.cacheWrite1h += b.cacheWrite1h
    }

    var tokens: Double { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

/// USD per token. The cache field names are those of api-prices.json.
struct Price: Codable, Equatable {
    var In = 0.0, Out = 0.0, CacheRead = 0.0, CacheWrite = 0.0, CacheWrite1h = 0.0

    func cost(_ u: Usage) -> Double {
        let read = CacheRead == 0 ? In : CacheRead
        let w5 = CacheWrite == 0 ? In : CacheWrite
        let w1 = CacheWrite1h == 0 ? w5 : CacheWrite1h
        return u.input * In + u.output * Out + u.cacheRead * read + u.cacheWrite5m * w5 + u.cacheWrite1h * w1
    }
}

public final class APICostTracker: @unchecked Sendable {
    static let scanEvery: Duration = .seconds(120)
    /// Today and the 29 days before it.
    static let days = 30
    static let pricesMaxAge: TimeInterval = 86400
    static let pricesURL = "https://openrouter.ai/api/v1/models"

    let claudeDir: String  // ~/.claude/projects
    let codexDir: String  // ~/.codex/sessions
    let cacheFile: String?  // where the price list is kept between runs
    let fetchPrices: (@Sendable () async throws -> Data)?  // nil: no network (tests)
    let now: @Sendable () -> Date
    let calendar: Calendar

    final class FileState {
        var off: UInt64 = 0
        var model = ""  // codex: from the last turn_context
        var prev: CodexTotals?  // codex: running totals, usage is their delta
    }

    // scan state, touched only on `queue`
    private let queue = DispatchQueue(label: "burnrate.apicost", qos: .utility)
    private var files: [String: FileState] = [:]
    private var seen: [String: String] = [:]  // message key → day, so a re-logged message counts once
    private var usage: [String: [String: [String: Usage]]] = [:]  // service → model → day → tokens
    var prices: [String: Price] = [:]
    var pricesAt: Date?

    public init(
        claudeDir: String, codexDir: String, cacheFile: String?, network: Bool = true,
        calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claudeDir = claudeDir
        self.codexDir = codexDir
        self.cacheFile = cacheFile
        self.calendar = calendar
        self.now = now
        fetchPrices = network ? Self.download : nil
    }

    @Sendable static func download() async throws -> Data {
        var req = URLRequest(url: URL(string: pricesURL)!)
        req.setValue("burnrate/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.failed("prices: HTTP error") }
        return data
    }

    /// Scans now and every two minutes, handing each result to publish, until cancelled.
    public func run(_ publish: @Sendable (APICost?) async -> Void) async {
        while !Task.isCancelled {
            await publish(await scan())
            try? await Task.sleep(for: Self.scanEvery)
        }
    }

    /// Reads what the logs gained since the last scan and recomputes the result.
    public func scan() async -> APICost? {
        let t = now()
        if let data = await pricesToFetch(t) { await onQueue { self.storePrices(data, t) } }
        return await onQueue { self.scanSync(t) }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: body()) } }
    }

    /// The fresh price list when the cached one is missing or a day old.
    private func pricesToFetch(_ t: Date) async -> Data? {
        let stale = await onQueue { () -> Bool in
            self.loadCachedPrices()
            guard let at = self.pricesAt, !self.prices.isEmpty else { return true }
            return t.timeIntervalSince(at) >= Self.pricesMaxAge
        }
        guard stale, let fetchPrices else { return nil }
        return try? await fetchPrices()  // on failure the cached list stays
    }

    private func loadCachedPrices() {
        guard prices.isEmpty, let cacheFile, let b = FileManager.default.contents(atPath: cacheFile),
            let c = try? JSONDecoder().decode(PriceCache.self, from: b), !c.prices.isEmpty
        else { return }
        prices = c.prices
        pricesAt = RFC3339.parse(c.at)
    }

    private func storePrices(_ data: Data, _ t: Date) {
        guard let p = try? Self.parsePrices(data) else { return }
        (prices, pricesAt) = (p, t)
        guard let cacheFile, let b = try? JSONEncoder().encode(PriceCache(at: Self.rfc3339(t), prices: p)) else { return }
        FileManager.default.createFile(atPath: cacheFile, contents: b, attributes: [.posixPermissions: 0o600])
    }

    struct PriceCache: Codable {
        var at: String
        var prices: [String: Price]
    }

    static func rfc3339(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    func scanSync(_ t: Date) -> APICost? {
        let start = calendar.date(byAdding: .day, value: -(Self.days - 1), to: calendar.startOfDay(for: t))!
        let first = dayString(start)
        prune(first)
        walk(claudeDir, start) { fst, line in self.claudeLine(line, start) }
        walk(codexDir, start) { fst, line in self.codexLine(fst, line, start) }
        return compute()
    }

    private func walk(_ dir: String, _ start: Date, _ line: (FileState, UnsafeRawBufferPointer) -> Void) {
        guard !dir.isEmpty else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard
            let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys,
                options: [], errorHandler: { _, _ in true })
        else { return }
        for case let u as URL in e where u.pathExtension == "jsonl" {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                let mod = v.contentModificationDate, mod >= start, let size = v.fileSize
            else { continue }
            let path = u.path
            let fst = files[path] ?? FileState()
            files[path] = fst
            if UInt64(size) < fst.off {  // rewritten: start over
                (fst.off, fst.model, fst.prev) = (0, "", nil)
            }
            if UInt64(size) == fst.off { continue }
            readFrom(path, fst) { line(fst, $0) }
        }
    }

    /// Feeds whole lines after fst.off; a line still being written waits for the next scan.
    private func readFrom(_ path: String, _ fst: FileState, _ fn: (UnsafeRawBufferPointer) -> Void) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        do { try h.seek(toOffset: fst.off) } catch { return }
        var carry = Data()
        while true {
            guard let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty else { return }
            carry.append(chunk)
            // everything up to the last newline is complete
            guard let lastNL = carry.lastIndex(of: 10) else { continue }
            let complete = carry[carry.startIndex...lastNL]
            Lines.each(Data(complete)) { fn($0) }
            fst.off += UInt64(complete.count)
            carry = Data(carry[carry.index(after: lastNL)...])
        }
    }

    private func add(_ service: String, _ model: String, _ day: String, _ u: Usage) {
        usage[service, default: [:]][model, default: [:]][day, default: Usage()] += u
    }

    /// Drops days that left the window; their files are never reread.
    private func prune(_ first: String) {
        for (svc, models) in usage {
            for (m, days) in models { usage[svc]![m] = days.filter { $0.key >= first } }
        }
        seen = seen.filter { $0.value >= first }
    }

    private func dayString(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The local day of a log timestamp inside the window.
    private func dayOf(_ ts: String?, _ start: Date) -> String? {
        guard let ts, let t = RFC3339.parse(ts), t >= start else { return nil }
        return dayString(t)
    }

    private struct ClaudeLine: Decodable {
        struct Message: Decodable {
            struct U: Decodable {
                struct Split: Decodable { var ephemeral_1h_input_tokens: Double? }
                var input_tokens: Double?
                var output_tokens: Double?
                var cache_creation_input_tokens: Double?
                var cache_read_input_tokens: Double?
                var cache_creation: Split?
            }
            var id: String?
            var model: String?
            var usage: U?
        }
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    private let decoder = JSONDecoder()

    /// One assistant message. Claude Code logs the same message once per
    /// content block, so message id + request id counts it once.
    private func claudeLine(_ b: UnsafeRawBufferPointer, _ start: Date) {
        guard Lines.contains(b, "\"usage\""),
            let l = try? decoder.decode(ClaudeLine.self, from: Data(b)),
            let msg = l.message, let u = msg.usage,
            let day = dayOf(l.timestamp, start)
        else { return }
        let m = msg.model ?? ""
        if m.isEmpty || m.hasPrefix("<") { return }  // <synthetic>: no API call behind it
        let id = msg.id ?? "", req = l.requestId ?? ""
        if !id.isEmpty || !req.isEmpty {
            let k = id + "|" + req
            if seen[k] != nil { return }
            seen[k] = day
        }
        let write = u.cache_creation_input_tokens ?? 0
        let h1 = u.cache_creation.map { min($0.ephemeral_1h_input_tokens ?? 0, write) } ?? 0
        add(
            "claude", m, day,
            Usage(
                input: u.input_tokens ?? 0, output: u.output_tokens ?? 0,
                cacheRead: u.cache_read_input_tokens ?? 0, cacheWrite5m: write - h1, cacheWrite1h: h1))
    }

    struct CodexTotals: Decodable {
        var input_tokens: Double?
        var cached_input_tokens: Double?
        var output_tokens: Double?

        var input: Double { input_tokens ?? 0 }
        var cached: Double { cached_input_tokens ?? 0 }
        var output: Double { output_tokens ?? 0 }
    }

    private struct CodexLine: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable { var total_token_usage: CodexTotals? }
            var type: String?
            var model: String?
            var info: Info?
        }
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    /// token_count events carry running session totals; the model comes from
    /// the turn_context before them.
    private func codexLine(_ fst: FileState, _ b: UnsafeRawBufferPointer, _ start: Date) {
        guard Lines.contains(b, "\"token_count\"") || Lines.contains(b, "\"turn_context\""),
            let l = try? decoder.decode(CodexLine.self, from: Data(b))
        else { return }
        if l.type == "turn_context" {
            if let m = l.payload?.model, !m.isEmpty { fst.model = m }
            return
        }
        guard l.payload?.type == "token_count", let cur = l.payload?.info?.total_token_usage else { return }
        var d = (input: cur.input, cached: cur.cached, output: cur.output)
        if let p = fst.prev, cur.input >= p.input, cur.output >= p.output {
            d = (cur.input - p.input, cur.cached - p.cached, cur.output - p.output)
        }
        fst.prev = cur
        guard let day = dayOf(l.timestamp, start), d.input != 0 || d.output != 0 else { return }
        let m = fst.model.isEmpty ? "unknown" : fst.model
        let cached = min(max(d.cached, 0), d.input)
        add("codex", m, day, Usage(input: d.input - cached, output: d.output, cacheRead: cached))
    }

    static let titles = ["claude": "Claude Code", "codex": "ChatGPT"]

    private func compute() -> APICost? {
        if prices.isEmpty { return nil }
        var res = APICost(days: Self.days, usd: 0, items: [])
        var unpriced = Set<String>()
        for svc in ["claude", "codex"] {
            guard let models = usage[svc], !models.isEmpty else { continue }
            var it = APIItem(name: svc, title: Self.titles[svc]!, usd: 0, tokens: 0)
            for (m, days) in models {
                guard let p = price(m) else {
                    unpriced.insert(m)
                    continue
                }
                for u in days.values {
                    it.usd += p.cost(u)
                    it.tokens += Int64(u.tokens)
                }
            }
            it.usd = round2(it.usd)
            res.usd += it.usd
            res.items.append(it)
        }
        if !unpriced.isEmpty { res.unpriced = unpriced.sorted() }
        res.usd = round2(res.usd)
        return res
    }

    /// Maps a log model id to OpenRouter's: claude-opus-5-5 → claude-opus-5.5,
    /// claude-haiku-4-5-20251001 → claude-haiku-4.5.
    static func normalize(_ m: String) -> String {
        var m = m
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        if m.hasPrefix("claude-") {
            m = m.replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: "-$1.$2", options: .regularExpression)
        }
        return m
    }

    /// Finds the model, dropping trailing name parts (gpt-5.5-codex → gpt-5.5).
    func price(_ model: String) -> Price? {
        var m = Self.normalize(model)
        while !m.isEmpty {
            if let p = prices[m] { return p }
            guard let i = m.lastIndex(of: "-") else { break }
            m = String(m[..<i])
        }
        return nil
    }

    /// OpenRouter's model list as per-token prices of the anthropic/ and openai/
    /// models, keyed without the vendor prefix.
    static func parsePrices(_ data: Data) throws -> [String: Price] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = o["data"] as? [[String: Any]]
        else { throw ProviderError.failed("prices: not a model list") }
        func f(_ m: [String: Any], _ k: String) -> Double { (m[k] as? String).flatMap(Double.init) ?? 0 }
        var out: [String: Price] = [:]
        for d in list {
            guard let full = d["id"] as? String, let slash = full.firstIndex(of: "/") else { continue }
            let vendor = full[..<slash], id = String(full[full.index(after: slash)...])
            guard vendor == "anthropic" || vendor == "openai", !id.contains(":") else { continue }
            let p = d["pricing"] as? [String: Any] ?? [:]
            out[id] = Price(
                In: f(p, "prompt"), Out: f(p, "completion"), CacheRead: f(p, "input_cache_read"),
                CacheWrite: f(p, "input_cache_write"), CacheWrite1h: f(p, "input_cache_write_1h"))
        }
        if out.isEmpty { throw ProviderError.failed("prices: no anthropic/openai models in the list") }
        return out
    }
}
