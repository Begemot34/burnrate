// A provider fetches one service's usage. Errors steer the scheduler: auth keeps
// the last data and retries at the normal pace, retryAfter backs off.
import Foundation
import Synchronization

public protocol Provider: Sendable {
    var name: String { get }
    var title: String { get }
    var link: String { get }
    /// Non-empty for link-only cards.
    var note: String { get }
    func fetch() async throws -> Snapshot
}

/// What a provider returns from one successful fetch.
public struct Snapshot: Sendable, Equatable {
    public var gauges: [Meter] = []
    public var facts: [Fact] = []
    /// Soft warning shown while data is still valid.
    public var hint = ""
    /// Feeds the sparkline and burn rate. balance: the value goes down as money
    /// is spent (credits left); otherwise it grows (spent).
    public var series: Double?
    public var balance = false
    /// Exact usage spend this calendar month, when the API has it.
    public var monthUSD: Double?
    /// > 0: series is a credit balance worth unitUSD each; the month spend is estimated from history.
    public var unitUSD: Double = 0
    /// Subscription plan id for the price table (claude_max_20x, chatgpt_plus…).
    public var plan = ""

    public init() {}
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    /// Credentials are missing or expired; the hint says what to do.
    case auth(String)
    /// The service asked to slow down.
    case retryAfter(TimeInterval)
    /// A non-2xx response.
    case http(Int, String)
    case failed(String)

    public var description: String {
        switch self {
        case .auth(let h): h
        case .retryAfter: "HTTP 429"
        case .http(let code, let body): body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        case .failed(let m): m
        }
    }

    func isCode(_ codes: Int...) -> Bool {
        if case .http(let c, _) = self { return codes.contains(c) }
        return false
    }
}

extension Error {
    /// The text shown on the card, scrubbed of anything token-like.
    var message: String { Scrub.text((self as? ProviderError)?.description ?? "\(self)") }

    func isCode(_ codes: Int...) -> Bool {
        guard case .http(let c, _) = self as? ProviderError else { return false }
        return codes.contains(c)
    }
}

/// Injected so tests can swap the network, the shell and the clock.
public struct Deps: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias Exec = @Sendable (_ env: [String: String], _ name: String, _ args: [String]) async throws -> Data

    public var transport: Transport
    public var exec: Exec
    public var now: @Sendable () -> Date

    public init(transport: @escaping Transport, exec: @escaping Exec, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.exec = exec
        self.now = now
    }

    public static let live = Deps(
        transport: HTTP.urlSession,
        exec: { env, name, args in
            try await Shell.run(name, args, env: env)
        })
}

public enum Scrub {
    private static let re = try! NSRegularExpression(
        pattern: #"(sk-[A-Za-z0-9_\-]{6})[A-Za-z0-9_\-]+|(r8_[A-Za-z0-9]{4})[A-Za-z0-9]+|(eyJ[A-Za-z0-9_\-]{6})[A-Za-z0-9_\-.]+|(Bearer )\S+"#)

    /// Cookies, auth headers and secret key/value pairs: `Cookie: ...` and `Authorization: ...`
    /// to the end of the line, then `sessionid=...`, `"token": "..."`, `OPENAI_API_KEY=...` and the like.
    private static let secrets = [
        try! NSRegularExpression(pattern: #"((?:Set-)?Cookie\s*:\s*).+"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"(Authorization["']?\s*:\s*["']?).+"#, options: .caseInsensitive),
        try! NSRegularExpression(
            pattern:
                #"(\b(?:sessionid|token|secret|password|api_?key|(?:access|refresh|id)_token|[A-Za-z0-9_]*(?:API_KEY|_TOKEN|_SECRET))["']?\s*[=:]\s*["']?)[^\s"';,&]+"#,
            options: .caseInsensitive),
    ]

    /// Cuts anything that looks like a token.
    public static func text(_ s: String) -> String {
        var out = s
        for r in secrets {
            out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1…")
        }
        return re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2$3$4…")
    }
}

/// The last line of s, at most 160 characters (a process's stderr).
func lastLine(_ s: String) -> String {
    var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let i = s.lastIndex(of: "\n") { s = String(s[s.index(after: i)...]) }
    return String(s.prefix(160))
}

// MARK: - loose JSON

/// Accepts JSON numbers and numeric strings; null and "" are 0.
struct LooseNumber: Decodable, Sendable {
    var value: Double

    init(_ v: Double = 0) { value = v }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = 0; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        let s = try c.decode(String.self)
        if s.isEmpty || s == "null" { value = 0; return }
        guard let d = Double(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number: \(s)")
        }
        value = d
    }
}

/// Accepts unix seconds, unix ms, or an RFC 3339 string; holds unix ms.
struct Epoch: Decodable, Sendable {
    var ms: Int64

    init(_ ms: Int64 = 0) { self.ms = ms }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { ms = 0; return }
        if let s = try? c.decode(String.self) {
            if s.isEmpty { ms = 0; return }
            guard let d = RFC3339.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad time: \(s)")
            }
            ms = Int64((d.timeIntervalSince1970 * 1000).rounded(.down))
            return
        }
        var v = try c.decode(Double.self)
        if v < 1e12 { v *= 1000 }
        ms = Int64(v)
    }
}

/// RFC 3339 with optional fractional seconds, parsed by hand: it runs once per
/// log line in apicost, where a formatter per call would dominate.
enum RFC3339 {
    static func parse<S: StringProtocol>(_ s: S) -> Date? {
        let b = Array(s.utf8)
        func num(_ i: Int, _ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in i..<i + n {
                let c = b[k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116 || b[10] == 32,
            b[13] == 58, b[16] == 58,
            let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
            let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2),
            (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61
        else { return nil }
        var i = 19
        var frac = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            let start = i
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                frac += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }
        guard i < b.count else { return nil }
        var offset = 0
        switch b[i] {
        case 90, 122:  // Z z
            i += 1
        case 43, 45:  // + -
            guard let oh = num(i + 1, 2), i + 3 < b.count, b[i + 3] == 58, let om = num(i + 4, 2) else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
            i += 6
        default:
            return nil
        }
        guard i == b.count else { return nil }
        let days = daysFromCivil(y, mo, d)
        let secs = Double(days * 86400 + h * 3600 + mi * 60 + sec - offset) + frac
        return Date(timeIntervalSince1970: secs)
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - gauge helpers

let hour5: TimeInterval = 5 * 3600
let week: TimeInterval = 7 * 86400

func ms(_ d: TimeInterval) -> Int64 { Int64(d * 1000) }

func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }

/// A "used" percent window; reset and window 0 mean unknown.
func pct(_ key: String, _ label: String, _ used: Double, _ resetAt: Int64, _ window: TimeInterval) -> Meter {
    Meter(
        key: key, label: label, kind: "percent", value: used, max: 100, dir: "used",
        resetAt: resetAt == 0 ? nil : resetAt, window: ms(window) == 0 ? nil : ms(window))
}

/// Money balances turn orange below $10 and red below $5.
let lowBalanceUSD = 10.0
let critBalanceUSD = 5.0

func moneyLeft(_ key: String, _ label: String, _ v: Double) -> Meter {
    Meter(key: key, label: label, kind: "money", value: v, dir: "left", warnBelow: lowBalanceUSD, critBelow: critBalanceUSD)
}

func money(_ v: Double) -> String { "$" + fixed(v, 2) }

/// Fixed-point with n decimals: no grouping, rounds half to even on the binary value.
func fixed(_ v: Double, _ n: Int) -> String { String(format: "%.\(n)f", v) }

/// A value shared across tasks behind a lock; a class, so structs holding it stay copyable.
final class Locked<T: Sendable>: Sendable {
    private let m: Mutex<T>

    init(_ v: T) { m = Mutex(v) }

    func withLock<R: Sendable>(_ body: (inout T) -> R) -> R { m.withLock { body(&$0) } }
}
