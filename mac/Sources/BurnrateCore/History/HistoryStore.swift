// One numeric series per source as append-only JSONL ({"t":ms,"v":value} per
// line), and the sparkline and burn rate derived from it.
// Owned by the scheduler actor: not thread-safe on its own.
import Foundation

final class HistoryStore {
    struct Point: Codable, Equatable {
        var t: Int64  // unix ms
        var v: Double
    }

    /// A full calendar month for monthDrop.
    static let keep: TimeInterval = 35 * 86400

    private let dir: String?  // nil = memory only
    private let writable: Bool  // false: load from disk, never append (burnratectl dump)
    private(set) var series: [String: [Point]] = [:]
    private let calendar: Calendar

    init(dir: String?, writable: Bool = true, calendar: Calendar = .current) {
        self.dir = dir
        self.writable = writable
        self.calendar = calendar
        if let dir, writable {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    private func path(_ name: String) -> String { dir! + "/" + name + ".jsonl" }

    /// Reads the kept part of a series from disk.
    func load(_ name: String, now: Date) {
        guard dir != nil, let data = FileManager.default.contents(atPath: path(name)) else { return }
        let from = ms(now.addingTimeInterval(-Self.keep))
        let dec = JSONDecoder()
        var pts: [Point] = []
        Lines.each(data) { line in
            if let p = try? dec.decode(Point.self, from: Data(line)), p.t >= from { pts.append(p) }
        }
        series[name] = pts
    }

    func add(_ name: String, at t: Date, _ v: Double) {
        let p = Point(t: ms(t), v: v)
        let from = ms(t.addingTimeInterval(-Self.keep))
        var pts = series[name] ?? []
        pts.append(p)
        if let i = pts.firstIndex(where: { $0.t >= from }), i > 0 { pts.removeFirst(i) }
        series[name] = pts
        guard dir != nil, writable else { return }
        let file = path(name)
        let fm = FileManager.default
        if !fm.fileExists(atPath: file) {
            fm.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((Self.line(p) + "\n").utf8))
    }

    /// {"t":…,"v":…} with the shortest float that round-trips, like most JSON encoders.
    static func line(_ p: Point) -> String { "{\"t\":\(p.t),\"v\":\(goFloat(p.v))}" }

    static func goFloat(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e21 { return String(Int64(v)) }
        return "\(v)"
    }

    /// Up to n values from the last 24 hours, evenly sampled.
    func spark(_ name: String, now: Date, n: Int) -> [Double]? {
        let from = ms(now.addingTimeInterval(-86400))
        let pts = (series[name] ?? []).filter { $0.t >= from }
        if pts.count < 2 { return nil }
        if pts.count <= n { return pts.map(\.v) }
        return (0..<n).map { pts[$0 * (pts.count - 1) / (n - 1)].v }
    }

    /// Spend per hour over the last 6 hours. balance: the series shrinks as money
    /// is spent. nil when there is not enough data or the series moved the wrong
    /// way (top-up, month reset).
    func burn(_ name: String, now: Date, balance: Bool) -> Double? {
        let from = ms(now.addingTimeInterval(-6 * 3600))
        let all = series[name] ?? []
        var i = all.count
        while i > 0, all[i - 1].t >= from { i -= 1 }
        let pts = all[i...]
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        let hours = Double(last.t - first.t) / 3_600_000
        if hours < 0.33 { return nil }
        var d = last.v - first.v
        if balance { d = -d }
        if d < 0 { return nil }
        return max(d, 0) / hours  // max: a flat balance gives -0, shown as "-0.0"
    }

    /// The start of now's month in local time.
    func monthStart(_ now: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    }

    /// Sums balance decreases since the 1st of now's month, skipping increases
    /// (top-ups). since is the month start when a point before it exists to
    /// compare against, otherwise the first point (partial).
    func monthDrop(_ name: String, now: Date) -> (drop: Double, since: Date)? {
        let start = monthStart(now)
        let from = ms(start)
        var pts = series[name] ?? []
        var i = 0
        while i < pts.count, pts[i].t < from { i += 1 }
        var since: Date
        if i > 0 {  // baseline: the last point before the month began
            i -= 1
            since = start
        } else if let p = pts.first {
            since = Date(timeIntervalSince1970: Double(p.t) / 1000)
        } else {
            return nil
        }
        pts = Array(pts[i...])
        var drop = 0.0
        for j in pts.indices.dropFirst() where pts[j - 1].v - pts[j].v > 0 {
            drop += pts[j - 1].v - pts[j].v
        }
        return (drop, since)
    }
}
