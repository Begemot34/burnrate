import Foundation
import Testing
@testable import BurnrateCore

@Suite struct ModelTests {
    private func fixture() throws -> ServerState {
        let url = Bundle.module.url(forResource: "state", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(ServerState.self, from: Data(contentsOf: url))
    }

    @Test func decodesDemoState() throws {
        let st = try fixture()
        #expect(st.demo)
        #expect(st.sources.map(\.name) == ["claude", "codex", "openrouter", "replicate", "higgsfield"])
        let or = st.sources[2]
        #expect(or.gauges.isEmpty == false)
        #expect(or.gauges[0].max == nil && or.gauges[0].warnBelow == 10 && or.gauges[0].critBelow == 5)
        #expect(st.total?.items.contains { $0.kind == "subscription" } == true)
    }

    @Test func decodesPace() throws {
        let json = #"{"key":"d7","label":"7D WINDOW","kind":"percent","value":13,"max":100,"dir":"used","resetAt":1,"window":604800000,"pace":34.2,"elapsed":38,"paceLevel":"under"}"#
        let g = try JSONDecoder().decode(Meter.self, from: Data(json.utf8))
        #expect(g.window == 604_800_000 && g.pace == 34.2 && g.elapsed == 38 && g.paceLevel == "under")
        let bare = try JSONDecoder().decode(Meter.self, from: Data(#"{"key":"h5","label":"5H","kind":"percent","value":2}"#.utf8))
        #expect(bare.pace == nil && bare.paceLevel == nil)
        #expect(Format.paceTip(g) == "34% by reset at this pace, room to burn more. 13% used, 38% of the window gone.")
        #expect(Format.paceTip(bare) == nil)
    }

    @Test func tolerantDecoding() throws {
        let s = try JSONDecoder().decode(Source.self, from: Data(#"{"name":"x","status":"weird","facts":[["A","B"]]}"#.utf8))
        #expect(s.status == .unknown && s.title == "x" && s.gauges.isEmpty && s.facts == [Fact("A", "B")])
    }

    @MainActor @Test func placeholdersGiveWayToFirstSnapshot() throws {
        let store = Store(placeholders: true)
        #expect(store.isPlaceholder && store.order.count == 5)
        #expect(store.sources["claude"]?.gauges.count == 3)
        var st = try fixture()
        st.sources = Array(st.sources.prefix(2))
        store.apply(st)
        #expect(!store.isPlaceholder && store.order == ["claude", "codex"])
    }

    @MainActor @Test func reconnectDropsSwitchedOffSources() throws {
        let store = Store()
        store.apply(try fixture())
        var st = try fixture()
        st.sources.removeAll { $0.name == "higgsfield" }
        store.apply(st)
        #expect(!store.order.contains("higgsfield") && store.sources["higgsfield"] == nil && store.order.count == 4)
    }

    @MainActor @Test func storeKeepsOrderAndAppends() throws {
        let store = Store()
        store.apply(try fixture())
        var extra = store.ordered[0]
        extra.name = "new"
        store.apply(.source(extra))
        #expect(store.order.last == "new" && store.order.count == 6)
    }
}

@Suite struct FormatTests {
    @Test func countdowns() {
        #expect(Format.left(ms: 0) == "NOW")
        #expect(Format.left(ms: 9_000) == "00M 09S")
        #expect(Format.left(ms: 3_900_000) == "1H 05M")
        #expect(Format.left(ms: 2 * 86_400_000 + 4 * 3_600_000) == "2D 04H")
        #expect(Format.age(ms: 9_000) == "09S")
        #expect(Format.age(ms: 720_000) == "12M")
        #expect(Format.age(ms: 5 * 3_600_000) == "5H")
        #expect(Format.age(ms: 3 * 86_400_000) == "3D")
    }

    @Test func values() {
        #expect(Format.value(kind: "percent", 42.6) == "43%")
        #expect(Format.value(kind: "money", 1234.5) == "$1,234.50")
        #expect(Format.value(kind: "credits", 410.55) == "410.6")
        #expect(Format.month("2026-10") == "OCT 2026")
    }

    @Test func levels() {
        let left = Meter(key: "l", label: "L", kind: "money", value: 0, dir: "left", warnBelow: 10, critBelow: 5)
        #expect(Format.level(left, 12) == .normal)
        #expect(Format.level(left, 7) == .warn)
        #expect(Format.level(left, 3) == .crit)
        let used = Meter(key: "u", label: "U", kind: "percent", value: 0, max: 100, dir: "used")
        #expect(Format.level(used, 50) == .normal)
        #expect(Format.level(used, 80) == .warn)
        #expect(Format.level(used, 95) == .crit)
        var sev = used
        sev.severity = "crit"
        #expect(Format.level(sev, 1) == .crit)
        var own = used
        (own.warnAt, own.critAt) = (50, 70)
        #expect(Format.level(own, 60) == .warn && Format.level(own, 70) == .crit && Format.level(own, 40) == .normal)
        var share = own
        share.dir = "left"
        #expect(Format.level(share, 40) == .warn && Format.level(share, 30) == .crit && Format.level(share, 60) == .normal)
    }

    @Test func balancedColumns() {
        #expect(GridColumns.balanced(fit: 6, count: 5) == 5)  // wide screen: one row, no empty slot
        #expect(GridColumns.balanced(fit: 5, count: 5) == 5)
        #expect(GridColumns.balanced(fit: 4, count: 5) == 3)  // 13–14" laptop: 3 + 2, not 4 + 1
        #expect(GridColumns.balanced(fit: 3, count: 5) == 3)
        #expect(GridColumns.balanced(fit: 2, count: 5) == 2)
        #expect(GridColumns.balanced(fit: 1, count: 5) == 1)
        #expect(GridColumns.balanced(fit: 4, count: 7) == 4)
        #expect(GridColumns.balanced(fit: 0, count: 3) == 1)
        #expect(GridColumns.balanced(fit: 3, count: 0) == 3)
    }
}

@Suite struct MenuSummaryTests {
    private func sources(_ json: String) throws -> [Source] {
        try JSONDecoder().decode([Source].self, from: Data(json.utf8))
    }

    @Test func labels() {
        #expect(MenuSummary.shortLabel("5H WINDOW") == "5H")
        #expect(MenuSummary.shortLabel("7D FABLE") == "FABLE")
        #expect(MenuSummary.shortLabel("7D WINDOW") == "7D")
    }

    @Test func headlinePicksMostUsedThenAlerts() throws {
        let calm = try sources(
            """
            [{"name":"claude","gauges":[{"key":"h5","label":"5H WINDOW","kind":"percent","value":42,"max":100,"dir":"used"},
                                        {"key":"d7","label":"7D WINDOW","kind":"percent","value":61,"max":100,"dir":"used"}]},
             {"name":"openrouter","gauges":[{"key":"left","label":"CREDITS LEFT","kind":"money","value":18,"dir":"left","warnBelow":10,"critBelow":5}]}]
            """)
        #expect(MenuSummary.headline(calm) == Headline(text: "61%", level: .normal))

        let low = try sources(
            """
            [{"name":"codex","gauges":[{"key":"h5","label":"5H WINDOW","kind":"percent","value":80,"max":100,"dir":"used"}]},
             {"name":"replicate","gauges":[{"key":"left","label":"CREDITS LEFT","kind":"money","value":3.5,"dir":"left","warnBelow":10,"critBelow":5}]}]
            """)
        #expect(MenuSummary.headline(low) == Headline(text: "REP $3.50", level: .crit))
        #expect(MenuSummary.balance(low[1])?.key == "left")
        #expect(MenuSummary.balance(low[0]) == nil)
    }

    @Test func lowsListCriticalLimitsAndBalances() throws {
        let list = try sources(
            """
            [{"name":"codex","title":"Codex","link":"https://c","gauges":[{"key":"h5","label":"5H WINDOW","kind":"percent","value":94,"max":100,"dir":"used","resetAt":5},
                                                      {"key":"d7","label":"7D WINDOW","kind":"percent","value":61,"max":100,"dir":"used"}]},
             {"name":"openrouter","title":"OpenRouter","link":"https://o","gauges":[{"key":"left","label":"CREDITS LEFT","kind":"money","value":3.5,"dir":"left","warnBelow":10,"critBelow":5}]}]
            """)
        let lows = MenuSummary.lows(list)
        #expect(lows.map(\.value) == ["94%", "$3.50"])
        #expect(lows[0].resetAt == 5 && !lows[0].isBalance && lows[1].isBalance && lows[1].link == "https://o")
    }
}

@Suite struct BoringFormatTests {
    @Test func labelsAndTimes() {
        #expect(Format.niceLabel("5H WINDOW") == "5-hour")
        #expect(Format.niceLabel("7D FABLE") == "7-day · Fable")
        #expect(Format.niceLabel("SPENT TODAY") == "Spent today")
        #expect(Format.span(ms: (3 * 3600 + 5 * 60) * 1000) == "3 h 05 min")
        #expect(Format.span(ms: 22 * 60_000) == "22 min")
        #expect(Format.span(ms: (3 * 86400 + 2 * 3600) * 1000) == "3 d 02 h")
        #expect(Format.span(ms: 0) == "now")
        #expect(Format.ago(ms: 9000) == "9 s ago")
        #expect(Format.ago(ms: 120_000) == "2 min ago")
        #expect(Format.factsLine([Fact("PLAN", "MAX 20×"), Fact("EXTRA", "OFF")]) == "Max 20× · Off")
    }
}

@Suite struct WidgetSnapshotTests {
    @Test func paceOffKeepsElapsed() throws {
        let url = Bundle.module.url(forResource: "state", withExtension: "json", subdirectory: "Fixtures")!
        var st = try JSONDecoder().decode(ServerState.self, from: Data(contentsOf: url))
        st.sources[0].gauges[0].pace = 80
        st.sources[0].gauges[0].paceLevel = "over"
        st.sources[0].gauges[0].elapsed = 40
        let on = WidgetSnapshot(sources: st.sources, look: "boring", savedAt: 1_000)
        let off = WidgetSnapshot(sources: st.sources, look: "boring", savedAt: 1_000, showPace: false)
        #expect(on.rows[0].items[0].pace == 80)
        #expect(off.rows[0].items[0].pace == nil && off.rows[0].items[0].paceLevel == nil)
        #expect(off.rows[0].items[0].elapsed == 40)
    }

    @Test func buildsRowsAndRoundTrips() throws {
        let url = Bundle.module.url(forResource: "state", withExtension: "json", subdirectory: "Fixtures")!
        let st = try JSONDecoder().decode(ServerState.self, from: Data(contentsOf: url))
        let snap = WidgetSnapshot(sources: st.sources, look: "boring", savedAt: 1_000)
        #expect(snap.headline == MenuSummary.headline(st.sources))
        // the demo Replicate card has neither limits nor a balance, so it gets no row
        #expect(snap.rows.map(\.name) == ["claude", "codex", "openrouter", "higgsfield"])
        // limit sources list their windows, balance sources one value
        #expect(snap.rows[0].items.first?.label == "5H")
        #expect(snap.rows[2].items.count == 1)
        // limits carry the bar and the pace, balances neither
        let limit = st.sources[0].gauges.first { $0.kind == "percent" }!
        #expect(snap.rows[0].items[0].used == limit.value)
        #expect(snap.rows[0].items[0].pace == limit.pace)
        #expect(snap.rows[2].items[0].isBalance)
        #expect(snap.rows[1].title == "ChatGPT")
        // the small widget leads with what the menu bar shows
        #expect(snap.lead?.item.value == snap.headline.map { $0.text.split(separator: " ").last.map(String.init)! })

        let file = FileManager.default.temporaryDirectory.appending(path: "burnrate-test-\(UUID())/widget.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try snap.save(to: file)
        #expect(WidgetSnapshot.load(from: file) == snap)
        var later = snap
        later.savedAt = 2_000
        #expect(later.sameContent(snap))
        later.look = "cyberpunk"
        #expect(!later.sameContent(snap))
    }
}

@Suite struct WidgetFileTests {
    @Test func savesPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "burnrate-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "sub/widget.json")
        let snap = WidgetSnapshot(savedAt: 1, look: "boring", headline: nil, rows: [])
        try snap.save(to: url)
        try snap.save(to: url)
        func mode(_ u: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try mode(url) == 0o600)
        #expect(try mode(url.deletingLastPathComponent()) == 0o700)
        #expect(WidgetSnapshot.load(from: url) == snap)
    }
}
