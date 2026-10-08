// UserDefaults keys the Settings window writes and the views read.
import BurnrateCore

enum Prefs {
    /// Draw the pace forecast; the elapsed tick on the bars stays either way.
    static let showPace = "showPace"
    static let settingsTab = "settingsTab"
}

extension Meter {
    /// The meter as drawn: without the forecast when Settings turned it off.
    func paced(_ show: Bool) -> Meter {
        guard !show else { return self }
        var m = self
        (m.pace, m.paceLevel) = (nil, nil)
        return m
    }
}
