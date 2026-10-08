// Owns the engine and the store; one per app, shared by the window and the
// menu bar panel.
import AppKit
import BurnrateCore
import Observation
import WidgetKit
import os

private let log = Logger(subsystem: "burnrate", category: "widget")

@MainActor @Observable
final class AppModel {
    let store = Store(placeholders: true)
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var started = false
    @ObservationIgnored lazy var settings = SettingsModel(app: self)
    /// Why the engine could not start (a broken config.json).
    private(set) var failure: String?

    func start() {
        guard !started else { return }
        started = true
        // keep polling while the window is hidden (App Nap)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "live limits")
        reload()
        Task { await feedWidget() }
    }

    /// (Re)starts the engine from the config on disk: at launch and after Settings
    /// saved. The cards of a switched-off provider go with the old engine's state.
    func reload() {
        // launch args land in UserDefaults: open Burnrate.app --args -demo YES
        let demo = UserDefaults.standard.bool(forKey: "demo")
        let config: Config
        do {
            config = try Config.load(keychain: demo ? nil : Keychain.live)
            failure = nil
        } catch {
            failure = "\(error)"
            return
        }
        run?.cancel()
        let engine = Engine(config: config, demo: demo)
        self.engine = engine
        store.connect(engine)
        run = Task.detached(priority: .utility) { await engine.run() }
    }

    /// Writes the widget snapshot every 30 s when it changed (at least every 5 min, so
    /// the widget can tell fresh from stale) and wakes the widget only when the alert
    /// level or the look moves, or 15 min passed: the system allows a few dozen reloads
    /// a day. The look is checked every 5 s so switching it shows on the desktop at once.
    private func feedWidget() async {
        var last: WidgetSnapshot?
        var builtAt = Date.distantPast
        var reloadedAt = Date.distantPast
        var lastPace = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            // demo numbers must not replace the real snapshot on the desktop
            guard !store.isPlaceholder, !store.demo else { continue }
            let now = Date()
            let look = Look(rawValue: UserDefaults.standard.string(forKey: Look.key) ?? "") ?? .initial
            let pace = UserDefaults.standard.object(forKey: Prefs.showPace) as? Bool ?? true
            let paceMoved = pace != lastPace
            guard now.timeIntervalSince(builtAt) >= 30 || look.rawValue != last?.look || paceMoved else { continue }
            builtAt = now
            let snap = WidgetSnapshot(
                sources: store.ordered, look: look.rawValue,
                savedAt: Int64(now.timeIntervalSince1970 * 1000), showPace: pace)
            lastPace = pace
            let changed = last.map { !$0.sameContent(snap) } ?? true
            let old = last.map { now.timeIntervalSince1970 * 1000 - Double($0.savedAt) > 300_000 } ?? true
            guard changed || old else { continue }
            do {
                try snap.save()
            } catch {
                log.error("widget snapshot: \(error.localizedDescription, privacy: .public)")
                continue
            }
            log.debug("widget snapshot saved, level \(snap.level.rawValue, privacy: .public)")
            if snap.level != last?.level || snap.look != last?.look || paceMoved || now.timeIntervalSince(reloadedAt) > 900 {
                WidgetCenter.shared.reloadAllTimelines()
                reloadedAt = now
            }
            last = snap
        }
    }
}
