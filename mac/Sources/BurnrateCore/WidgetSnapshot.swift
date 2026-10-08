// What the desktop widget shows. The app writes it next to the history,
// the sandboxed widget only reads it: no network, no shared App Group.
import Foundation

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var level: Level
        /// limit reset, server ms; nil for balances
        public var resetAt: Int64?
        /// percent used, for the bar; nil for balances
        public var used: Double?
        /// share of the window gone and the forecast at reset, in percent; level is under | on | over
        public var elapsed: Double?
        public var pace: Double?
        public var paceLevel: String?
        public var id: String { label }

        public init(
            label: String, value: String, level: Level, resetAt: Int64? = nil, used: Double? = nil,
            elapsed: Double? = nil, pace: Double? = nil, paceLevel: String? = nil
        ) {
            self.label = label; self.value = value; self.level = level; self.resetAt = resetAt; self.used = used
            self.elapsed = elapsed; self.pace = pace; self.paceLevel = paceLevel
        }

        public var isBalance: Bool { used == nil }
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        /// "Claude Code", "ChatGPT": the Cyberpunk view uppercases it
        public var title: String
        public var stale: Bool
        public var items: [Item]
        public var id: String { name }

        public init(name: String, title: String, stale: Bool, items: [Item]) {
            self.name = name; self.title = title; self.stale = stale; self.items = items
        }
    }

    /// ms since 1970
    public var savedAt: Int64
    /// the app's look: boring | cyberpunk
    public var look: String
    public var headline: Headline?
    public var rows: [Row]

    public init(savedAt: Int64, look: String, headline: Headline?, rows: [Row]) {
        self.savedAt = savedAt; self.look = look; self.headline = headline; self.rows = rows
    }

    /// Limits as in the menu bar panel; a balance only for sources without limits.
    /// showPace false drops the forecast and keeps the elapsed tick.
    public init(sources: [Source], look: String, savedAt: Int64, showPace: Bool = true) {
        let rows = sources.compactMap { s -> Row? in
            var items = s.gauges.filter { $0.kind == "percent" }.map {
                Item(
                    label: MenuSummary.shortLabel($0.label), value: Format.value(kind: $0.kind, $0.value),
                    level: Format.level($0, $0.value), resetAt: ($0.resetAt ?? 0) > 0 ? $0.resetAt : nil,
                    used: $0.value, elapsed: $0.elapsed, pace: showPace ? $0.pace : nil,
                    paceLevel: showPace ? $0.paceLevel : nil)
            }
            if let b = MenuSummary.balance(s) {
                items.append(
                    Item(
                        label: MenuSummary.shortLabel(b.label), value: Format.value(kind: b.kind, b.value),
                        level: Format.level(b, b.value)))
            }
            guard !items.isEmpty else { return nil }
            return Row(
                name: s.name, title: s.name == "codex" ? "ChatGPT" : s.title,
                stale: s.status == .stale || s.status == .dead, items: items)
        }
        self.init(savedAt: savedAt, look: look, headline: MenuSummary.headline(sources), rows: rows)
    }

    /// Worst level, for deciding when to wake the widget.
    public var level: Level { headline?.level ?? .normal }

    /// The small widget's item, picked like the menu bar headline: the worst level,
    /// on a tie the most used limit; a balance only when it runs low.
    public var lead: (row: Row, item: Item)? {
        var best: (rank: Int, used: Double, row: Row, item: Item)?
        for row in rows {
            for item in row.items {
                let rank = item.level == .crit ? 2 : item.level == .warn ? 1 : 0
                if item.isBalance && rank == 0 { continue }
                let used = item.used ?? -1
                guard best == nil || rank > best!.rank || (rank == best!.rank && used > best!.used) else { continue }
                best = (rank, used, row, item)
            }
        }
        return best.map { ($0.row, $0.item) }
    }

    /// Same content, ignoring when it was saved.
    public func sameContent(_ o: WidgetSnapshot) -> Bool {
        look == o.look && headline == o.headline && rows == o.rows
    }

    // MARK: file

    /// The real home: inside the sandbox NSHomeDirectory() is the container.
    public static var home: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var url: URL {
        home.appending(path: "Library/Application Support/burnrate/widget.json")
    }

    public static func load(from url: URL = url) -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    public func save(to url: URL = Self.url) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: try enc.encode(self), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
