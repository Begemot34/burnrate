// Card state for every view. Sources are replaced in place by name, so
// SwiftUI keeps identities and only changed leaves re-render.
import Foundation
import Observation

@MainActor @Observable
public final class Store {
    public private(set) var order: [String] = []
    public private(set) var sources: [String: Source] = [:]
    public private(set) var total: MonthTotal?
    public private(set) var demo = false
    /// Showing placeholder cards: no data from the engine yet.
    public private(set) var isPlaceholder = false
    /// When the last update arrived.
    public private(set) var updatedAt = Date()
    /// local view of refresh cooldowns, merged with what the engine says
    private var cooldowns: [String: Int64] = [:]

    private var engine: Engine?
    private var task: Task<Void, Never>?

    public init() {}

    /// placeholders: start with cards of the real shape, so the window is
    /// sized right before any data arrives (Apple's advice for async content).
    public convenience init(placeholders: Bool) {
        self.init()
        guard placeholders, let ph = try? JSONDecoder().decode([Source].self, from: Data(Self.placeholderJSON.utf8))
        else { return }
        for s in ph { put(s) }
        isPlaceholder = true
    }

    public var ordered: [Source] { order.compactMap { sources[$0] } }

    /// The clock the cards count down against.
    public func now(_ local: Date = Date()) -> Date { local }
    public func nowMs(_ local: Date = Date()) -> Int64 { Int64(local.timeIntervalSince1970 * 1000) }

    public func cooldownUntil(_ name: String) -> Int64 {
        max(cooldowns[name] ?? 0, sources[name]?.cooldownUntil ?? 0)
    }

    /// Shows the engine's current state, then follows its updates.
    public func connect(_ engine: Engine) {
        self.engine = engine
        task?.cancel()
        task = Task { [weak self] in
            let st = await engine.state()
            self?.apply(st)
            for await u in engine.updates {
                guard let self else { return }
                self.apply(u)
            }
        }
    }

    public func apply(_ st: ServerState) {
        if isPlaceholder {
            order = []
            sources = [:]
            isPlaceholder = false
        }
        demo = st.demo
        // a full state: a source missing from it was switched off in Settings
        let names = Set(st.sources.map(\.name))
        order.removeAll { !names.contains($0) }
        sources = sources.filter { names.contains($0.key) }
        for s in st.sources { put(s) }
        total = st.total
        updatedAt = Date()
    }

    public func apply(_ u: Update) {
        switch u {
        case .source(let s): put(s)
        case .total(let t): total = t
        }
        updatedAt = Date()
    }

    private func put(_ s: Source) {
        if sources[s.name] == nil { order.append(s.name) }
        if sources[s.name] != s { sources[s.name] = s }
    }

    public func refresh(_ name: String?) async {
        guard let engine, let until = await engine.refresh(name) else { return }
        for n in order where name == nil || n == name {
            cooldowns[n] = max(cooldowns[n] ?? 0, until)
        }
    }
}

extension Store {
    /// Same shape as the real cards: gauge, fact and reset-line counts match.
    static let placeholderJSON = """
        [
         {"name":"claude","title":"Claude Code","status":"fetching","gauges":[
           {"key":"h5","label":"5H WINDOW","kind":"percent","value":0,"max":100,"dir":"used","resetAt":1},
           {"key":"d7","label":"7D WINDOW","kind":"percent","value":0,"max":100,"dir":"used","resetAt":1},
           {"key":"d7_m","label":"7D MODEL","kind":"percent","value":0,"max":100,"dir":"used","resetAt":1}],
          "facts":[["PLAN","----"],["TIER","----"],["7D SPLIT","----"],["EXTRA","----"]],"spark":[0,0]},
         {"name":"codex","title":"Codex","status":"fetching","gauges":[
           {"key":"h5","label":"5H WINDOW","kind":"percent","value":0,"max":100,"dir":"used","resetAt":1},
           {"key":"d7","label":"7D WINDOW","kind":"percent","value":0,"max":100,"dir":"used","resetAt":1}],
          "facts":[["PLAN","----"],["MODEL","----"],["LIMIT RESETS","-"]],"spark":[0,0]},
         {"name":"openrouter","title":"OpenRouter","status":"fetching","gauges":[
           {"key":"left","label":"CREDITS LEFT","kind":"money","value":0},
           {"key":"day","label":"SPENT TODAY","kind":"money","value":0},
           {"key":"month","label":"SPENT MONTH","kind":"money","value":0}],"facts":[],"spark":[0,0]},
         {"name":"replicate","title":"Replicate","status":"fetching","gauges":[
           {"key":"left","label":"CREDITS LEFT","kind":"money","value":0},
           {"key":"month","label":"SPENT MONTH","kind":"money","value":0}],
          "facts":[["USER","----"],["BURN","----"]],"spark":[0,0]},
         {"name":"higgsfield","title":"Higgsfield","status":"fetching","gauges":[
           {"key":"credits","label":"CREDITS","kind":"credits","value":0}],
          "facts":[["PLAN","----"],["≈ USD","----"],["BURN","----"]],"spark":[0,0]}
        ]
        """
}
