// The two presentations of the same data: Boring follows the system,
// Cyberpunk is the BLACK SITE look as designed in the mockups.
import SwiftUI

enum Look: String, CaseIterable, Identifiable {
    case cyberpunk, boring  // picker order

    /// Until the user picks one; the choice is remembered across launches.
    static let initial = Look.cyberpunk

    /// UserDefaults key; `--args -look cyberpunk` overrides it for one launch.
    static let key = "look"

    var id: String { rawValue }
    var title: String { self == .boring ? "Boring" : "Cyberpunk" }
    var toggled: Look { self == .boring ? .cyberpunk : .boring }

    /// Cyberpunk is dark only; Boring takes light or dark from the system.
    var scheme: ColorScheme? { self == .cyberpunk ? .dark : nil }
}
