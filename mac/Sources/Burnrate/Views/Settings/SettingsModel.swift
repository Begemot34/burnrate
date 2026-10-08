// What the Settings window edits: config.json and the Keychain. Every change is
// saved at once (no OK button) and restarts the engine, so the cards follow.
import BurnrateCore
import Foundation
import Observation

@MainActor @Observable
final class SettingsModel {
    private(set) var config = Config()
    /// The keys in the Keychain, by variable name; read when the window opens.
    private(set) var stored: [String: String] = [:]
    /// A config.json that cannot be read is never overwritten.
    private(set) var error: String?
    /// The provider section Settings scrolls to; set by a card's "Settings" link.
    var focus: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private unowned let app: AppModel

    private var demo: Bool { UserDefaults.standard.bool(forKey: "demo") }

    init(app: AppModel) {
        self.app = app
    }

    func load() {
        do {
            config = try Config.load(keychain: nil)
            error = nil
        } catch {
            self.error = "\(error)"
        }
        // demo touches no account: no keys read, so none reach a -snapshot PNG either
        guard !demo else { return }
        Task {
            let s = await Task.detached { Keychain.readAll(Keychain.live) }.value
            stored = s
        }
    }

    /// Applies a change and saves it shortly after, so a run of clicks restarts the engine once.
    func edit(_ change: (inout Config) -> Void) {
        guard error == nil else { return }
        change(&config)
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        do {
            try config.save()
            app.reload()
        } catch {
            self.error = "Cannot save config.json: \(error.localizedDescription)"
        }
    }

    /// Opens on Providers at that provider's section.
    func show(provider name: String) {
        UserDefaults.standard.set(SettingsView.Pane.providers.rawValue, forKey: Prefs.settingsTab)
        focus = name
    }

    func provider(_ name: String) -> Config.ProviderConfig {
        config.providers[name] ?? .init()
    }

    func setSecret(_ name: String, _ value: String?) {
        guard !demo else { return }
        Task {
            let result = await Task.detached {
                Result {
                    if let value { try Keychain.write(name, value, Keychain.live) } else { try Keychain.delete(name, Keychain.live) }
                }
            }.value
            if case .failure(let e) = result { error = "\(e)" }
            stored = await Task.detached { Keychain.readAll(Keychain.live) }.value
            app.reload()
        }
    }
}
