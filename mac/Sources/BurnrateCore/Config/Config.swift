// Loads ~/.config/burnrate/config.json over the defaults, then the pipeline .env
// and the Keychain (the Keychain wins); Settings writes it back. The intervals are
// duration strings like "5m" or "1h30m".
import Foundation

public struct Config: Sendable {
    public struct ProviderConfig: Sendable, Equatable {
        public var enabled = true
        public var interval: TimeInterval = 0
        /// Overrides the subscription price from the plan table (taxes, regional
        /// prices, ChatGPT Pro $100); 0 hides the subscription.
        public var monthlyUSD: Double?
        /// Lets a provider also call undocumented endpoints with the local login
        /// (Codex: chatgpt.com usage, adds per-model availability).
        public var unofficial = false

        public init(enabled: Bool = true, interval: TimeInterval = 0, monthlyUSD: Double? = nil, unofficial: Bool = false) {
            self.enabled = enabled; self.interval = interval; self.monthlyUSD = monthlyUSD; self.unofficial = unofficial
        }
    }

    /// When a bar turns orange and red: percent of a limit used, dollars of a balance left.
    public struct Thresholds: Sendable, Equatable {
        public var warnPct = 75.0
        public var critPct = 90.0
        public var warnUSD = 10.0
        public var critUSD = 5.0

        public init() {}
    }

    public var historyDir = "~/Library/Application Support/burnrate/history"
    public var envFile = "~/.config/burnrate/.env"
    public var codexHome = "~/.codex"
    public var claudeHome = "~/.claude"
    public var providers: [String: ProviderConfig] = Config.defaultProviders
    public var thresholds = Thresholds()
    public var dir = ""
    public var secrets: [String: String] = [:]

    /// Card order.
    public static let order = ["claude", "codex", "openrouter", "replicate", "higgsfield"]

    static let defaultProviders: [String: ProviderConfig] = [
        "claude": .init(interval: 300), "codex": .init(interval: 300), "openrouter": .init(interval: 120),
        "replicate": .init(interval: 900), "higgsfield": .init(interval: 600),
    ]

    public init() {}

    public static var defaultDir: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/burnrate").path
    }

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    /// A missing config.json is fine; a broken one is an error. keychain nil skips the
    /// Keychain (tests, and Settings, which reads keys on its own).
    public static func load(_ dir: String = defaultDir, keychain: Keychain.Run?) throws -> Config {
        var c = Config()
        c.dir = dir
        let path = dir + "/config.json"
        if let b = FileManager.default.contents(atPath: path) {
            do {
                try c.apply(json: b)
            } catch {
                throw ConfigError(description: "config.json: \(error)")
            }
        }
        for (name, def) in defaultProviders where c.providers[name] == nil { c.providers[name] = def }
        c.historyDir = expand(c.historyDir)
        c.envFile = expand(c.envFile)
        c.codexHome = expand(c.codexHome)
        c.claudeHome = expand(c.claudeHome)
        c.secrets = readEnv(c.envFile) ?? [:]
        if let keychain { c.secrets.merge(Keychain.readAll(keychain)) { _, new in new } }
        return c
    }

    /// Fields present in the JSON replace the defaults; a provider entry is taken whole.
    mutating func apply(json: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ConfigError(description: "not an object")
        }
        if let v = o["history_dir"] as? String { historyDir = v }
        if let v = o["env_file"] as? String { envFile = v }
        if let v = o["codex_home"] as? String { codexHome = v }
        if let v = o["claude_home"] as? String { claudeHome = v }
        if let ps = o["providers"] as? [String: Any] {
            for (name, raw) in ps {
                guard let p = raw as? [String: Any] else { continue }
                var pc = ProviderConfig(enabled: false)
                pc.enabled = p["enabled"] as? Bool ?? false
                if let s = p["interval"] as? String {
                    guard let d = DurationString.parse(s) else {
                        throw ConfigError(description: "providers.\(name).interval: bad duration \(s)")
                    }
                    pc.interval = d
                }
                pc.monthlyUSD = (p["monthly_usd"] as? NSNumber)?.doubleValue
                pc.unofficial = p["unofficial"] as? Bool ?? false
                providers[name] = pc
            }
        }
        if let t = o["thresholds"] as? [String: Any] {
            func num(_ k: String) -> Double? { (t[k] as? NSNumber)?.doubleValue }
            thresholds.warnPct = num("warn_pct") ?? thresholds.warnPct
            thresholds.critPct = num("crit_pct") ?? thresholds.critPct
            thresholds.warnUSD = num("warn_usd") ?? thresholds.warnUSD
            thresholds.critUSD = num("crit_usd") ?? thresholds.critUSD
        }
    }

    /// Writes the providers and thresholds into config.json; every other key in the
    /// file stays as it is. A provider entry is written whole, since a missing
    /// `enabled` reads as false.
    public func save() throws {
        let path = dir + "/config.json"
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { _ = try Self.initFiles(dir) }
        var o: [String: Any] = [:]
        if let b = fm.contents(atPath: path) {
            guard let x = try JSONSerialization.jsonObject(with: b) as? [String: Any] else {
                throw ConfigError(description: "config.json: not an object")
            }
            o = x
        }
        var ps = o["providers"] as? [String: Any] ?? [:]
        for (name, pc) in providers {
            var p = ps[name] as? [String: Any] ?? [:]
            p["enabled"] = pc.enabled
            p["interval"] = DurationString.format(pc.interval)
            p["monthly_usd"] = pc.monthlyUSD
            if pc.unofficial || p["unofficial"] != nil { p["unofficial"] = pc.unofficial }
            ps[name] = p
        }
        o["providers"] = ps
        let t = thresholds
        o["thresholds"] = ["warn_pct": t.warnPct, "crit_pct": t.critPct, "warn_usd": t.warnUSD, "crit_usd": t.critUSD]
        let data = try JSONSerialization.data(
            withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public static func expand(_ p: String) -> String {
        if p == "~" || p.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst()
        }
        return p
    }

    /// KEY=VALUE lines; # comments, optional export and quotes. nil when the file is missing.
    public static func readEnv(_ path: String) -> [String: String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }

    static var defaultJSON: String {
        let ps = order.map { name -> String in
            let p = defaultProviders[name]!
            return "    \"\(name)\": {\n      \"enabled\": true,\n      \"interval\": \"\(DurationString.format(p.interval))\"\n    }"
        }.joined(separator: ",\n")
        return """
            {
              "history_dir": "~/Library/Application Support/burnrate/history",
              "env_file": "~/.config/burnrate/.env",
              "codex_home": "~/.codex",
              "claude_home": "~/.claude",
              "providers": {
            \(ps)
              }
            }

            """
    }

    /// Writes config.json if it doesn't exist yet; returns what was written. Keys go to
    /// the Keychain (Settings or `burnratectl secret set`).
    public static func initFiles(_ dir: String = defaultDir) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var made: [String] = []
        for (name, body) in [("config.json", defaultJSON)] {
            let p = dir + "/" + name
            if fm.fileExists(atPath: p) { continue }
            guard fm.createFile(atPath: p, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw ConfigError(description: "cannot write \(p)")
            }
            made.append(p)
        }
        return made
    }
}

/// Duration strings like "1h30m0s" (parse and format), for the intervals in config.json.
enum DurationString {
    private static let units: [(String, Double)] = [
        ("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("μs", 1e-6), ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600),
    ]

    static func parse(_ s: String) -> TimeInterval? {
        var rest = Substring(s)
        var sign = 1.0
        if let f = rest.first, f == "-" || f == "+" {
            sign = f == "-" ? -1 : 1
            rest = rest.dropFirst()
        }
        if rest == "0" { return 0 }
        guard !rest.isEmpty else { return nil }
        var total = 0.0
        while !rest.isEmpty {
            let num = rest.prefix { $0.isNumber || $0 == "." }
            guard !num.isEmpty, let v = Double(num) else { return nil }
            rest = rest.dropFirst(num.count)
            let u = rest.prefix { !($0.isNumber || $0 == ".") }
            guard let (_, scale) = units.first(where: { $0.0 == u }) else { return nil }
            rest = rest.dropFirst(u.count)
            total += v * scale
        }
        return sign * total
    }

    /// "5m0s", "1h30m0s", "15s" for whole seconds.
    static func format(_ d: TimeInterval) -> String {
        let t = Int(d)
        if t == 0 { return "0s" }
        let h = t / 3600, m = t % 3600 / 60, s = t % 60
        if h > 0 { return "\(h)h\(m)m\(s)s" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }
}
