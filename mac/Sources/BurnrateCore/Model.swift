// The card state the engine produces and `burnratectl dump` prints. Decoding is
// tolerant: missing optional fields and unknown statuses never fail a snapshot.
import Foundation

public enum Status: String, Codable, Sendable {
    case ok, stale, error, dead, fetching, link, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Status(rawValue: raw) ?? .unknown
    }
}

public struct Meter: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var kind: String  // percent | money | credits
    public var value: Double
    public var max: Double?
    public var dir: String?  // used | left
    public var resetAt: Int64?
    public var warnBelow: Double?
    public var critBelow: Double?
    public var severity: String?
    public var window: Int64?
    /// Percent expected at the reset if the window's average pace holds; elapsed is the share gone, in percent.
    public var pace: Double?
    public var elapsed: Double?
    public var paceLevel: String?  // under | on | over
    /// Percent of max at which a limit turns orange and red; nil: 75 and 90.
    public var warnAt: Double?
    public var critAt: Double?

    public var id: String { key }

    public init(
        key: String, label: String, kind: String, value: Double, max: Double? = nil, dir: String? = nil,
        resetAt: Int64? = nil, warnBelow: Double? = nil, critBelow: Double? = nil, severity: String? = nil,
        window: Int64? = nil, pace: Double? = nil, elapsed: Double? = nil, paceLevel: String? = nil
    ) {
        self.key = key; self.label = label; self.kind = kind; self.value = value; self.max = max; self.dir = dir
        self.resetAt = resetAt; self.warnBelow = warnBelow; self.critBelow = critBelow; self.severity = severity
        self.window = window; self.pace = pace; self.elapsed = elapsed; self.paceLevel = paceLevel
    }
}

/// A label/value pair; on the wire it is a two-element array.
public struct Fact: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { label }

    public init(_ label: String, _ value: String) { self.label = label; self.value = value }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        label = try c.decode(String.self)
        value = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(label)
        try c.encode(value)
    }
}

public struct Source: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var title: String
    public var status: Status
    public var interval: Int64
    public var link: String
    public var note: String?
    public var gauges: [Meter]
    public var facts: [Fact]
    public var spark: [Double]?
    public var fetchedAt: Int64
    public var lastOkAt: Int64
    public var nextRefreshAt: Int64
    public var cooldownUntil: Int64
    public var lastError: String
    public var hint: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, title, status, interval, link, note, gauges, facts, spark
        case fetchedAt, lastOkAt, nextRefreshAt, cooldownUntil, lastError, hint
    }

    public init(
        name: String, title: String, status: Status, interval: Int64, link: String, note: String? = nil,
        gauges: [Meter] = [], facts: [Fact] = [], spark: [Double]? = nil, fetchedAt: Int64 = 0,
        lastOkAt: Int64 = 0, nextRefreshAt: Int64 = 0, cooldownUntil: Int64 = 0, lastError: String = "",
        hint: String = ""
    ) {
        self.name = name; self.title = title; self.status = status; self.interval = interval; self.link = link
        self.note = note; self.gauges = gauges; self.facts = facts; self.spark = spark; self.fetchedAt = fetchedAt
        self.lastOkAt = lastOkAt; self.nextRefreshAt = nextRefreshAt; self.cooldownUntil = cooldownUntil
        self.lastError = lastError; self.hint = hint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .unknown
        interval = try c.decodeIfPresent(Int64.self, forKey: .interval) ?? 0
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        gauges = try c.decodeIfPresent([Meter].self, forKey: .gauges) ?? []
        facts = try c.decodeIfPresent([Fact].self, forKey: .facts) ?? []
        spark = try c.decodeIfPresent([Double].self, forKey: .spark)
        fetchedAt = try c.decodeIfPresent(Int64.self, forKey: .fetchedAt) ?? 0
        lastOkAt = try c.decodeIfPresent(Int64.self, forKey: .lastOkAt) ?? 0
        nextRefreshAt = try c.decodeIfPresent(Int64.self, forKey: .nextRefreshAt) ?? 0
        cooldownUntil = try c.decodeIfPresent(Int64.self, forKey: .cooldownUntil) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
    }

    /// Text under the gauges: the note for link cards, else the error or hint.
    public var message: String {
        status == .link ? (note ?? "") : (lastError.isEmpty ? hint : lastError)
    }
}

public struct MonthItem: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var title: String
    public var kind: String  // usage | subscription
    public var usd: Double
    public var estimate: Bool?
    public var partial: Bool?
    public var since: Int64?
    public var missing: Bool?
    public var plan: String?
    public var priceFrom: String?
    public var id: String { name }
}

public struct MonthTotal: Codable, Equatable, Sendable {
    public var month: String  // 2026-10
    public var usage: Double
    public var subs: Double
    public var total: Double
    public var estimate: Bool
    public var items: [MonthItem]
    /// The last `days` days of subscription usage on this Mac at API list prices.
    public var api: APICost?
}

public struct APICost: Codable, Equatable, Sendable {
    public var days: Int?
    public var usd: Double

    public var label: String { "API \(days ?? 30)D ≈ " }
    public var items: [APIItem]
    public var unpriced: [String]?

    public func usd(for name: String) -> Double? { items.first { $0.name == name }?.usd }
}

public struct APIItem: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var title: String
    public var usd: Double
    public var tokens: Int64
    public var id: String { name }
}

public struct ServerState: Codable, Sendable {
    public var serverTime: Int64
    public var demo: Bool
    public var sources: [Source]
    public var total: MonthTotal?
}
