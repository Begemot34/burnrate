// The engine, in process: builds the providers
// from the config, runs the scheduler and the API-price tracker, and streams
// card updates to whoever displays them.
import Foundation

public final class Engine: Sendable {
    public let demo: Bool
    public let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private let scheduler: Scheduler
    private let tracker: APICostTracker?

    /// Real accounts from the config, or fake drifting data with demo.
    /// readOnly: history is loaded but never written (a one-off dump beside the app).
    public convenience init(config: Config, demo: Bool, readOnly: Bool = false) {
        let items = Self.items(config, demo: demo)
        let tracker =
            demo
            ? nil
            : APICostTracker(
                claudeDir: config.claudeHome + "/projects", codexDir: config.codexHome + "/sessions",
                cacheFile: config.historyDir + "/api-prices.json")
        self.init(
            items: items, historyDir: demo ? nil : config.historyDir, historyWritable: !readOnly,
            tracker: tracker, demo: demo, thresholds: config.thresholds)
    }

    init(
        items: [Item], historyDir: String?, historyWritable: Bool = true, tracker: APICostTracker?, demo: Bool,
        thresholds: Config.Thresholds = .init(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.demo = demo
        self.tracker = tracker
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        scheduler = Scheduler(
            items, historyDir: historyDir, historyWritable: historyWritable, thresholds: thresholds, now: now)
    }

    public static func items(_ cfg: Config, demo: Bool) -> [Item] {
        let ps: [any Provider]
        if demo {
            ps = Demo.all()
        } else {
            let d = Deps.live, sec = cfg.secrets
            ps = [
                Claude(deps: d),
                Codex(deps: d, home: cfg.codexHome, unofficial: cfg.providers["codex"]?.unofficial ?? false),
                OpenRouter(deps: d, key: sec["OPENROUTER_API_KEY"] ?? ""),
                Replicate(deps: d, sessionID: sec["REPLICATE_SESSIONID"] ?? ""),
                Higgsfield(deps: d),
            ]
        }
        return ps.compactMap { p in
            guard let pc = cfg.providers[p.name], pc.enabled else { return nil }
            var iv = pc.interval
            if demo && iv > 0 { iv = 15 }
            if !p.note.isEmpty { iv = 0 }
            return Item(p, interval: iv, monthlyUSD: pc.monthlyUSD)
        }
    }

    /// Polls until the task is cancelled.
    public func run() async {
        await scheduler.setContinuation(continuation)
        if demo { await scheduler.setAPICost(Demo.apiCost) }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.scheduler.run() }
            if let tracker {
                g.addTask { await tracker.run { await self.scheduler.setAPICost($0) } }
            }
        }
    }

    /// Every card and the month total, as of now.
    public func state() async -> ServerState {
        let sources = await scheduler.sources()
        let t = scheduler.now()
        return ServerState(serverTime: ms(t), demo: demo, sources: sources, total: await scheduler.total(t))
    }

    /// Asks for an immediate fetch (nil = every source); returns the cooldown end in unix ms.
    public func refresh(_ name: String?) async -> Int64? {
        guard await scheduler.known(name) else { return nil }
        return await scheduler.refresh(name).until
    }

    /// One fetch of every source, without the scheduler: for `burnratectl check`.
    public static func fetchOnce(_ items: [Item]) async -> [(Item, Result<Snapshot, any Error>)] {
        var out: [(Item, Result<Snapshot, any Error>)] = []
        for it in items {
            out.append((it, it.interval == 0 ? .success(Snapshot()) : await Scheduler.fetch(it.provider)))
        }
        return out
    }

    /// One poll of every source and one log scan, then the state: for `burnratectl dump`.
    public func dumpOnce() async -> ServerState {
        await scheduler.pollOnce()
        if demo {
            await scheduler.setAPICost(Demo.apiCost)
        } else if let tracker {
            await scheduler.setAPICost(await tracker.scan())
        }
        return await state()
    }
}
